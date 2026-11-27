import AppKit
import GhosttyKit

/// Ghostty showing a terminal it didn't open (ANSER_SELFTEST_ONLY=adopt): the base for kept
/// shells without the `attach` relay. Opens a pty with a small shell loop behind it, hands the
/// pty to a surface with some history, and checks that the history comes first, typing and
/// resizing reach the shell, recent output is kept, and closing the surface leaves the shell
/// running and Ghostty's copy of the pty closed.
extension SelfTest {
    @MainActor
    static func adoptChecks() async -> [(String, Bool, String)] {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append(("adopt: " + name, ok, ok ? "" : detail)) }

        var master: Int32 = -1, slave: Int32 = -1
        var ws = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &ws) == 0 else { check("pty opened", false); return results }
        defer { if master >= 0 { close(master) } }

        let script = """
        printf 'adopt-ready\\n'
        while IFS= read -r l; do
          case "$l" in size) printf 'size:%s\\n' "$(stty size)";; *) printf 'got:%s\\n' "$l";; esac
        done
        """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script + " # anser-selftest-adopt"]
        let tty = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        shell.standardInput = tty; shell.standardOutput = tty; shell.standardError = tty
        do { try shell.run() } catch { check("shell started", false, "\(error)"); close(slave); return results }
        close(slave)
        defer { if shell.isRunning { shell.terminate() } }

        // Let the shell print before Ghostty takes over, so its line waits in the pty
        // and has to come after the history.
        var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 3000)

        let history = Array("restored-line-1\r\nrestored-line-2\r\n".utf8)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TerminalSurfaceView(workingDirectory: nil, command: nil, env: [:],
                                       adoptPTY: master, initialOutput: history)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        guard let surface = view.surface else { check("surface created", false); return results }

        func text() -> String { view.viewportText() ?? "" }
        let shown = await wait(5) { text().contains("adopt-ready") }
        let t = text()
        if let h = t.range(of: "restored-line-2"), let r = t.range(of: "adopt-ready") {
            check("history shown before the shell's output", h.lowerBound < r.lowerBound)
        } else {
            check("history shown before the shell's output", false, shown ? t : "nothing shown: \(t)")
        }

        view.sendText("hello\r")
        check("typing reaches the shell", await wait(5) { text().contains("got:hello") }, text())

        window.setContentSize(NSSize(width: 520, height: 300))
        await sleep(0.3)
        let size = ghostty_surface_size(surface)
        view.sendText("size\r")
        let want = "size:\(size.rows) \(size.columns)"
        check("resize reaches the shell", await wait(5) { text().contains(want) }, "want \(want), screen: \(text())")

        var buf = [UInt8](repeating: 0, count: 1 << 21)
        let n = ghostty_surface_recent_output(surface, &buf, buf.count)
        let recent = String(decoding: buf[0..<n], as: UTF8.self)
        check("recent output kept", recent.hasPrefix("restored-line-1") && recent.contains("got:hello"), recent)
        check("output total counted", ghostty_surface_recent_output_total(surface) >= UInt64(n) && n > 0)

        // Closing the surface must not touch the shell.
        view.destroy()
        await sleep(0.3)
        check("shell survives closing the surface", shell.isRunning)

        // It still answers through our own copy of the pty. Ghostty made it non-blocking.
        _ = "after\n".withCString { write(master, $0, 6) }
        var got = ""
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !got.contains("got:after") {
            var p = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 200) > 0 else { continue }
            var b = [UInt8](repeating: 0, count: 4096)
            let r = read(master, &b, b.count)
            if r > 0 { got += String(decoding: b[0..<r], as: UTF8.self) }
        }
        check("shell answers after the surface closed", got.contains("got:after"), got)

        // Once our copy closes, nobody holds the pty any more: the shell sees it hang
        // up and ends. If Ghostty leaked its copy, it would keep running.
        close(master); master = -1
        check("Ghostty closed its copy of the pty", await wait(5) { !shell.isRunning })
        return results
    }
}

/// Kept tabs reading the shell's own terminal (ANSER_SELFTEST_ONLY=direct): the helper hands it
/// over, the shell gets the environment a plain tab's shell gets, and reattaching, the busy
/// check, "open in another window", the shell exiting and the `attach` fallback all still work.
extension SelfTest {
    @MainActor
    static func directChecks(_ pane: PaneView, _ wc: TerminalWindowController) async -> [(String, Bool, String)] {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append((name, ok, ok ? "" : detail)) }
        let tmp = NSTemporaryDirectory()
        guard SessionHost.shared.enabled else { check("direct: kept shells are on", false, "helper missing or setting off"); return results }
        func shown(_ p: PaneView) -> String { p.surfaceView.viewportText() ?? "" }
        func ready(_ p: PaneView) async -> Bool { await wait(30) { p.session.integrated && p.session.atPrompt } }
        func isOpen(_ p: PaneView) -> Bool { wc.allPanesEverywhere.contains { $0 === p } }

        _ = await ready(pane)
        check("direct: a kept tab reads the shell's own terminal", pane.direct != nil && pane.session.persistent)

        // The shell's environment matches what Ghostty gives a shell it starts itself.
        pane.run("printf 'env:%s|%s|%s|%s|%s\\n' \"$TERM\" \"$TERM_PROGRAM\" \"${GHOSTTY_BIN_DIR:+bin}\" \"$SHLVL\" \"${PWD:+pwd}\" # anser-selftest")
        // SHLVL counts up from Anser's own (set when a script launched it), as in a plain tab.
        let level = (Int(ProcessInfo.processInfo.environment["SHLVL"] ?? "") ?? 0) + 1
        let want = "env:xterm-ghostty|Anser|bin|\(level)|pwd"
        check("direct: the shell's environment is a plain tab's", await wait(10) { shown(pane).contains(want) },
              shown(pane).components(separatedBy: "\n").first { $0.hasPrefix("env:") } ?? shown(pane))

        // Busy: a program in front of the shell, seen on the terminal itself.
        pane.run("sleep 3 # anser-selftest")
        let busy = await wait(3) { pane.direct?.busy == true }
        _ = await wait(6) { pane.session.atPrompt }
        check("direct: a running program is seen on the terminal", busy && pane.direct?.busy == false)

        // Restart: let go of the tab, keeping the shell; it comes back with its history.
        wc.addTab(cwd: tmp)
        let kp = wc.focusedPane!
        _ = await ready(kp)
        kp.run("export ANSER_KEPT=direct-7; echo direct-before-marker # anser-selftest")
        _ = await wait(10) { shown(kp).contains("direct-before-marker") && kp.session.atPrompt }
        let id = kp.session.id
        SessionHost.shared.save(kp.session)
        kp.keepShellOnClose = true
        wc.closeTab(wc.tabs.count - 1)
        await sleep(0.5)
        check("direct: the shell keeps running after its tab is gone", SessionHost.shared.liveIDs().contains(id))
        SessionHost.shared.refreshLive()
        wc.addTab(restoring: .pane(cwd: tmp, session: id))
        let back = wc.focusedPane!
        check("direct: it comes back reading the terminal directly", back.direct != nil && back.session.id == id)
        check("direct: its history is shown again", await wait(5) { shown(back).contains("direct-before-marker") }, shown(back))
        back.run("echo value=$ANSER_KEPT # anser-selftest")
        check("direct: it's the same shell", await wait(10) { shown(back).contains("value=direct-7") }, shown(back))

        // Opened in another window: the first tab closes, the shell carries on in the second.
        wc.addTab(restoring: .pane(cwd: tmp, session: id))
        let second = wc.focusedPane!
        let closedFirst = await wait(5) { !isOpen(back) }
        check("direct: opening it elsewhere closes the old tab", closedFirst)
        check("direct: …without ending the shell", SessionHost.shared.liveIDs().contains(id))
        second.run("echo again=$ANSER_KEPT # anser-selftest")
        check("direct: the new tab has the shell", await wait(10) { shown(second).contains("again=direct-7") }, shown(second))

        // The shell exits: its tab closes and the helper lets the shell go.
        second.run("exit")
        check("direct: exiting the shell closes its tab", await wait(5) { !isOpen(second) })
        check("direct: …and the helper forgets it", await wait(5) { !SessionHost.shared.liveIDs().contains(id) })

        // Fallback: tabs still work through `attach` when the terminal isn't handed over.
        PaneView.directKeptTabs = false
        wc.addTab(cwd: tmp)
        let relay = wc.focusedPane!
        PaneView.directKeptTabs = true
        let up = await ready(relay)
        relay.run("echo relay-ok # anser-selftest")
        let relayed = await wait(10) { shown(relay).contains("relay-ok") }
        check("direct: the attach fallback still works", up && relay.direct == nil && relay.session.persistent && relayed, shown(relay))
        wc.closeTab(wc.tabs.count - 1)

        // Crash: the tab never hands its history back, but the 5-second snapshot already did.
        wc.addTab(cwd: tmp)
        let cp = wc.focusedPane!
        _ = await ready(cp)
        let cid = cp.session.id
        func replayBytes() -> Int { SessionHost.shared.request(["cmd": "replaySize", "id": cid])?["bytes"] as? Int ?? 0 }
        cp.run("echo snap-before-marker # anser-selftest")
        _ = await wait(10) { shown(cp).contains("snap-before-marker") && cp.session.atPrompt }
        let start = replayBytes()
        let sent = await wait(DirectTerminal.snapshotInterval + 3) { replayBytes() > start }
        check("direct: an open tab sends its history every few seconds", cp.direct != nil && sent, "replay \(start) → \(replayBytes())")
        cp.direct?.close()            // as if Anser died: no hand-back
        SessionHost.shared.save(cp.session)
        cp.keepShellOnClose = true
        wc.closeTab(wc.tabs.count - 1)
        await sleep(0.3)
        SessionHost.shared.refreshLive()
        wc.addTab(restoring: .pane(cwd: tmp, session: cid))
        let after = wc.focusedPane!
        check("direct: after a crash, the snapshot's history comes back",
              await wait(5) { shown(after).contains("snap-before-marker") }, shown(after))
        wc.closeTab(wc.tabs.count - 1)
        wc.window?.makeKeyAndOrderFront(nil)
        return results
    }
}

/// Kept tabs stream as fast as plain ones (ANSER_SELFTEST_ONLY=keptperf): 50 MB through a kept
/// (direct) tab and a plain tab in the same run, alternating, best of three each. Kept must be
/// within 1.3× of plain; through the old `attach` relay it was about 2×.
extension SelfTest {
    @MainActor
    static func keptPerfChecks(_ wc: TerminalWindowController) async -> [(String, Bool, String)] {
        let dir = NSTemporaryDirectory() + "anser-selftest-perf"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/out.txt"
        if ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0) < 50_000_000 {
            var line = ""
            for i in 0..<64 { line += "line \(i) of some ordinary terminal output with words and numbers 1234567890 \u{1b}[32mok\u{1b}[0m\n" }
            let data = Data(String(repeating: line, count: 80).utf8)
            FileManager.default.createFile(atPath: file, contents: nil)
            if let h = FileHandle(forWritingAtPath: file) {
                var size = 0
                while size < 50_000_000 { h.write(data); size += data.count }
                try? h.close()
            }
        }
        func open(kept: Bool) async -> PaneView {
            Services.shared.setKeepShellsForTest(kept)
            wc.addTab(cwd: dir)
            Services.shared.setKeepShellsForTest(true)
            let p = wc.focusedPane!
            _ = await wait(30) { p.session.integrated && p.session.atPrompt }
            return p
        }
        let kept = await open(kept: true), plain = await open(kept: false)
        var times: [Bool: [Double]] = [true: [], false: []]
        var run = 0
        for _ in 0..<3 {
            for (isKept, p) in [(true, kept), (false, plain)] {
                run += 1
                let tag = "anser-selftest-keptperf-\(run)"
                await sleep(0.5)
                let t0 = Date()
                p.run("cat \(file) # \(tag)")
                _ = await wait(120) { p.session.atPrompt && p.session.blocks.last?.command.contains(tag) == true && p.session.blocks.last?.duration != nil }
                times[isKept]!.append(Date().timeIntervalSince(t0))
            }
        }
        let k = times[true]!.min()!, pl = times[false]!.min()!
        func list(_ v: [Double]) -> String { v.map { String(format: "%.2f", $0) }.joined(separator: ", ") }
        let detail = String(format: "kept %@ s · plain %@ s · best %.2f vs %.2f (%.2f×)", list(times[true]!), list(times[false]!), k, pl, k / pl)
        note("perf: 50 MB " + detail)
        let results = [
            ("keptperf: the kept tab reads its shell directly", kept.direct != nil && plain.direct == nil && !plain.session.persistent, ""),
            ("keptperf: a kept tab streams within 1.3× of a plain one", k <= pl * 1.3, detail),
        ]
        wc.closeTab(wc.tabs.count - 1); wc.closeTab(wc.tabs.count - 1)
        return results
    }
}

/// Anser killed with -9 and relaunched (scripts/test-crash-relaunch.sh drives both halves):
/// the kept shell is still alive and its history comes back from the last snapshot.
extension SelfTest {
    /// First half (ANSER_SELFTEST_ONLY=crash1): output in a kept tab, a snapshot sent, the id
    /// written to ANSER_CRASH_FILE. The script then kills the app; this never finishes.
    @MainActor
    static func crashBefore(_ pane: PaneView) async {
        _ = await wait(30) { pane.session.integrated && pane.session.atPrompt }
        let id = pane.session.id
        func replayBytes() -> Int { SessionHost.shared.request(["cmd": "replaySize", "id": id])?["bytes"] as? Int ?? 0 }
        pane.run("export ANSER_CRASH=alive-9; echo crash-history-marker # anser-selftest")
        _ = await wait(10) { (pane.surfaceView.viewportText() ?? "").contains("crash-history-marker") && pane.session.atPrompt }
        let start = replayBytes()
        let sent = await wait(DirectTerminal.snapshotInterval + 3) { replayBytes() > start }
        let file = ProcessInfo.processInfo.environment["ANSER_CRASH_FILE"] ?? NSTemporaryDirectory() + "anser-crash-id"
        try? "\(id) \(pane.direct != nil && sent ? "ok" : "no-snapshot")".write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// Second half (ANSER_SELFTEST_ONLY=crash2, ANSER_SELFTEST_KEEP=id).
    @MainActor
    static func crashAfter(_ wc: TerminalWindowController) async -> [(String, Bool, String)] {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append((name, ok, ok ? "" : detail)) }
        let id = ProcessInfo.processInfo.environment["ANSER_SELFTEST_KEEP"] ?? ""
        await sleep(0.5)   // launch's clean-up of unclaimed shells runs in the background
        check("after kill -9: the kept shell is still running", SessionHost.shared.liveIDs().contains(id), id)
        SessionHost.shared.refreshLive()
        wc.addTab(restoring: .pane(cwd: NSHomeDirectory(), session: id))
        let p = wc.focusedPane!
        func shown() -> String { p.surfaceView.viewportText() ?? "" }
        check("after kill -9: the tab reattaches directly", p.direct != nil && p.session.id == id)
        check("after kill -9: its history is shown", await wait(5) { shown().contains("crash-history-marker") }, shown())
        p.run("echo still=$ANSER_CRASH # anser-selftest")
        check("after kill -9: it's the same shell", await wait(10) { shown().contains("still=alive-9") }, shown())
        return results
    }

    /// The helper doesn't hand terminals over (ANSER_SELFTEST_ONLY=fallback, with a helper started
    /// with ANSER_SESSION_IGNORE_DIRECT=1, like one left from an older Anser): tabs start through
    /// `attach` and work; only the first waits for the handoff.
    @MainActor
    static func fallbackChecks(_ pane: PaneView, _ wc: TerminalWindowController) async -> [(String, Bool, String)] {
        var results: [(String, Bool, String)] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append((name, ok, ok ? "" : detail)) }
        func works(_ p: PaneView, _ tag: String) async -> Bool {
            guard await wait(30, { p.session.integrated && p.session.atPrompt }) else { return false }
            p.run("echo \(tag) # anser-selftest")
            return await wait(10) { (p.surfaceView.viewportText() ?? "").contains(tag) }
        }
        let first = await works(pane, "fallback-first-ok")
        check("fallback: a tab works through attach when the helper won't hand over",
              first && pane.direct == nil && pane.session.persistent, pane.surfaceView.viewportText() ?? "")
        let t0 = Date()
        wc.addTab(cwd: nil)
        let opened = Date().timeIntervalSince(t0)
        let second = wc.focusedPane!
        let ok = await works(second, "fallback-second-ok")
        check("fallback: later tabs don't wait for it again", ok && second.direct == nil && opened < 0.5,
              String(format: "opened in %.2f s", opened))
        wc.closeTab(wc.tabs.count - 1)
        return results
    }
}
