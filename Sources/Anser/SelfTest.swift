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
    }

    private static func finish() {
        // Keep the user's history clean.
        let h = Services.shared.history
        for c in h.search("", scope: .all, limit: 100000).map(\.0.command)
        where c.contains("anser-selftest") || c.contains("ANSER_SELFTEST") {
            h.delete(command: c)
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
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
        wc.showChanges(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("changed files list opens", ok)
        if let p = openPicker(), let v = p.contentView { snapView(v, "picker-changes"); p.close() }
        wc.showBranchSwitcher(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("branch switcher opens", ok)
        if let p = openPicker(), let v = p.contentView { snapView(v, "picker-branches"); p.close() }
        try? FileManager.default.createDirectory(atPath: tmp + "/folders/alpha/beta/gamma-target", withIntermediateDirectories: true)
        TerminalWindowController.resetFolderScanCache()
        wc.showFolderJumper(for: pane)
        ok = await wait(3) { openPicker() != nil }
        check("folder jumper opens", ok)
        if let p = openPicker() {
            p.setQuery("gamma")
            ok = await wait(5) { p.refresh(); return p.itemTitles.first?.hasSuffix("alpha/beta/gamma-target") == true }
            check("folder search finds a folder 3 levels down", ok, p.itemTitles.prefix(2).joined(separator: " | "))
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

        // Collapse a block's output.
        if let target = pane.blocksOverlay.blocks.first(where: { !$0.running && $0.bottom - $0.top > $0.rowHeight * 2 }) {
            pane.blocksOverlay.setCollapsed(target, true)
            let cover = pane.blocksOverlay.coverRect(target)
            let hit = pane.blocksOverlay.hitTest(pane.blocksOverlay.superview!.convert(NSPoint(x: cover.midX, y: cover.midY), from: pane.blocksOverlay))
            check("collapse covers a block's output", pane.blocksOverlay.isCollapsed(target) && hit === pane.blocksOverlay)
            snap(pane, "collapsed", full: true)
            pane.blocksOverlay.setCollapsed(target, false)
            check("expand shows it again", !pane.blocksOverlay.isCollapsed(target))
        } else {
            check("collapse covers a block's output", false, "no multi-line block on screen")
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
        check("narrow window folds buttons into …", pane.buttonsFolded)
        snap(pane, "narrow")
        wc.window!.setFrame(savedFrame, display: true)
        pane.layoutSubtreeIfNeeded()
        check("wide window shows the buttons", !pane.buttonsFolded)

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

        // Sidebar.
        wc.toggleSidebar()
        ok = await wait(5) { wc.sidebar.rowCount > 3 }
        check("sidebar lists git changes and folders", ok, "\(wc.sidebar.rowCount) rows, frame \(wc.sidebar.frame)")
        await sleep(0.5)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        snapView(wc.sidebar, "sidebar")
        wc.toggleSidebar()
        await sleep(0.3)

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
            check("workflow picker shows steps", p.previewString.contains("1. echo hello"))
            if let v = p.contentView { snapView(v, "picker-workflows") }
            p.close()
        }
        if let wf {
            let form = wc.makeParameterForm(wf)
            snapView(form.view, "workflow-form")
            check("parameter form uses the options", form.values()["who"] == "world")
            wc.runWorkflow(wf, values: ["who": "team"], in: pane)
            ok = await wait(10) { s.blocks.last?.command.contains("echo hello team") == true && s.atPrompt }
            await sleep(0.3)
            check("workflow runs its steps", ok && s.blocks.last?.exitCode == 0, s.blocks.last?.command ?? "-")
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
        Services.shared.aiForcedOn = false

        // ---- ssh: run the exact bootstrap ssh would send, in a nested local shell ----
        let before = s.blocks.count
        pane.run("zsh -c \"$(cat \"$ANSER_SSH_BOOTSTRAP\")\" # anser-selftest-ssh")
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
        pane.run("SHELL=/bin/bash zsh -c \"$(cat \"$ANSER_SSH_BOOTSTRAP\")\" # anser-selftest-ssh-bash")
        ok = await wait(40) { s.isRemote && s.atPrompt && s.env.shell == "bash" }
        check("remote bash connects", ok, s.env.shell)
        pane.run("echo bash-remote-ok # anser-selftest")
        ok = await wait(15) { s.blocks.last?.command.hasPrefix("echo bash-remote-ok") == true && s.atPrompt }
        check("remote bash records commands", ok && s.blocks.last?.exitCode == 0, s.blocks.last?.command ?? "-")
        pane.run("exit")
        ok = await wait(20) { !s.isRemote && s.atPrompt && s.running == nil }
        check("remote bash exits cleanly", ok)

        // ---- Stress ----
        func hangs() -> Int { Diagnostics.shared.recentBreadcrumbs.filter { $0.contains("HANG:") }.count }
        let hangsBefore = hangs()

        // Typing speed: 60 keystrokes through the full editor path.
        var t0 = Date()
        type(pane, "git commit -m 'stress test of typing speed in the editor' --amend")
        let perKey = Date().timeIntervalSince(t0) * 1000 / 60
        check("typing stays fast", perKey < 25, String(format: "%.1f ms per key (debug build)", perKey))
        pane.editor.clear()

        // Huge output.
        t0 = Date()
        pane.run("seq 1 3000000 # anser-selftest")
        ok = await wait(90) { s.blocks.last?.command.hasPrefix("seq 1 3000000") == true && s.atPrompt }
        let secs = Date().timeIntervalSince(t0)
        check("3 million lines of output", ok && secs < 30, String(format: "%.1fs", secs))

        // Resizing while output streams.
        let frame0 = wc.window!.frame
        pane.run("seq 1 1500000 # anser-selftest")
        for i in 0..<12 {
            wc.window!.setFrame(frame0.insetBy(dx: CGFloat(i % 3) * 40, dy: CGFloat(i % 2) * 30), display: true)
            await sleep(0.08)
        }
        wc.window!.setFrame(frame0, display: true)
        ok = await wait(60) { s.blocks.last?.command.hasPrefix("seq 1 1500000") == true && s.atPrompt }
        check("resizing during output", ok)

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

        // Settings window.
        SettingsWindowController.shared.show()
        await sleep(0.3)
        if let v = SettingsWindowController.shared.window?.contentView { snapView(v, "settings") }
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
        await sleep(0.3)
        check("command blocks panel opens", NSApp.windows.contains { $0 is PickerPanel && $0.isVisible })
        (NSApp.windows.first { $0 is PickerPanel } as? PickerPanel)?.close()

        // Completion sources.
        let r = await Services.shared.engine.complete(CompletionContext(line: "git chec", cursor: 8, cwd: s.cwd), env: s.env)
        check("git completion in live session", r.first?.insert == "checkout")
        let ls = await Services.shared.engine.complete(CompletionContext(line: "ls -", cursor: 4, cwd: s.cwd), env: s.env)
        check("ls flags read from its man page", ls.count >= 10, "\(ls.count) flags")
    }
}

final class SentBodies: @unchecked Sendable {
    private var bodies: [String] = []
    private let lock = NSLock()
    func add(_ b: String) { lock.withLock { bodies.append(b) } }
    var all: [String] { lock.withLock { bodies } }
}
