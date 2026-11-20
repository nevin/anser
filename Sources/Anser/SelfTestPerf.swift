import AppKit
import AnserCore

/// How Anser feels next to a plain terminal (ANSER_SELFTEST_ONLY=perf): what a keystroke
/// costs, how fast output streams, whether the UI stalls meanwhile, and how fast tabs open.
extension SelfTest {
    /// Measures how late the main thread answers, from a background thread every 5 ms.
    final class StallWatch: @unchecked Sendable {
        private let queue = DispatchQueue(label: "anser.selftest.stall")
        private var timer: DispatchSourceTimer?
        private let lock = NSLock()
        private var lags: [Double] = []
        private var waiting = false

        func start() {
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); let busy = self.waiting; self.waiting = true; self.lock.unlock()
                guard !busy else { return }
                let sent = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    self.lock.lock(); self.lags.append(lag); self.waiting = false; self.lock.unlock()
                }
            }
            timer = t
            t.resume()
        }

        /// Worst lag, 99th percentile and how many times the UI froze for over 50 ms.
        func stop() -> (max: Double, p99: Double, over50: Int) {
            timer?.cancel()
            lock.lock(); let l = lags.sorted(); lock.unlock()
            guard !l.isEmpty else { return (0, 0, 0) }
            return (l.last!, l[min(l.count - 1, Int(Double(l.count) * 0.99))], l.filter { $0 > 50 }.count)
        }
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double {
        let s = v.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    @MainActor
    static func perfChecks(_ pane: PaneView, _ wc: TerminalWindowController) async {
        _ = await wait(30) { pane.session.atPrompt }
        // Startup: from the process starting to the first prompt.
        if let start = ProcessScan.all().first(where: { $0.pid == getpid() })?.started {
            note(String(format: "perf: launch to first prompt %.0f ms", (pane.session.blocks.isEmpty ? Date() : Date()).timeIntervalSince(start) * 1000))
        }
        await sleep(3)

        // Typing: the main thread's work for each keystroke, until the editor has drawn it.
        pane.window?.makeFirstResponder(pane.editor)
        pane.editor.setTextForTests("")
        var keys: [Double] = [], inserts: [Double] = [], layouts: [Double] = [], draws: [Double] = []
        let text = "git log --oneline --graph --decorate --all -- Sources/Anser/Pane/PaneView.swift | grep -i perf | head -n 40"
        func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }
        for ch in text {
            let t0 = DispatchTime.now().uptimeNanoseconds
            pane.editor.insertText(String(ch), replacementRange: pane.editor.selectedRange())
            let t1 = DispatchTime.now().uptimeNanoseconds
            pane.layoutSubtreeIfNeeded()
            let t2 = DispatchTime.now().uptimeNanoseconds
            pane.window?.displayIfNeeded()
            let t3 = DispatchTime.now().uptimeNanoseconds
            inserts.append(ms(t0, t1)); layouts.append(ms(t1, t2)); draws.append(ms(t2, t3))
            keys.append(ms(t0, t3))
            // Let deferred work (suggestions, completions) run, like time between real keystrokes.
            await sleep(0.03)
        }
        note(String(format: "perf: keystroke avg %.2f ms · p95 %.2f ms · worst %.2f ms (%d keys)",
                    keys.reduce(0, +) / Double(keys.count), percentile(keys, 0.95), keys.max() ?? 0, keys.count))
        func avg(_ v: [Double]) -> Double { v.reduce(0, +) / Double(max(v.count, 1)) }
        note(String(format: "perf: per key: text handling %.2f ms (p95 %.2f) · layout %.2f ms (p95 %.2f) · drawing %.2f ms (p95 %.2f)",
                    avg(inserts), percentile(inserts, 0.95), avg(layouts), percentile(layouts, 0.95), avg(draws), percentile(draws, 0.95)))
        // What the deferred work after each key costs (suggestions, completions, lint), timed per part.
        PerfProbe.enabled = true
        pane.editor.setTextForTests("")
        for ch in text { pane.editor.insertText(String(ch), replacementRange: pane.editor.selectedRange()); await sleep(0.03) }
        await sleep(0.4)
        PerfProbe.enabled = false
        note("perf: per key, by part: " + PerfProbe.report())
        // Typing while the deferred work runs too: the main thread's lag.
        let typingWatch = StallWatch(); typingWatch.start()
        pane.editor.setTextForTests("")
        for ch in text { pane.editor.insertText(String(ch), replacementRange: pane.editor.selectedRange()); await sleep(0.012) }
        await sleep(0.5)
        let tl = typingWatch.stop()
        note(String(format: "perf: while typing fast, UI lag worst %.1f ms · p99 %.1f ms · freezes over 50 ms: %d", tl.max, tl.p99, tl.over50))
        pane.editor.setTextForTests("")

        // Output: 50 MB through the terminal, and the UI's lag while it streams.
        let dir = NSTemporaryDirectory() + "anser-selftest-perf"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/out.txt"
        if !FileManager.default.fileExists(atPath: file) {
            var line = ""
            for i in 0..<64 { line += "line \(i) of some ordinary terminal output with words and numbers 1234567890 \u{1b}[32mok\u{1b}[0m\n" }
            let chunk = String(repeating: line, count: 80)
            if let h = FileHandle(forWritingAtPath: file) ?? { FileManager.default.createFile(atPath: file, contents: nil); return FileHandle(forWritingAtPath: file) }() {
                let data = Data(chunk.utf8)
                var size = 0
                while size < 50_000_000 { h.write(data); size += data.count }
                try? h.close()
            }
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        for (label, cmd) in [("cat 50 MB", "cat \(file)"), ("seq 2M lines", "seq 1 2000000")] {
            _ = await wait(10) { pane.session.atPrompt }
            await sleep(0.5)
            let watch = StallWatch(); watch.start()
            let t0 = Date()
            pane.run("\(cmd) # anser-selftest-perf")
            _ = await wait(180) { pane.session.atPrompt && pane.session.blocks.last?.command.contains("anser-selftest-perf") == true && pane.session.blocks.last?.duration != nil }
            let secs = Date().timeIntervalSince(t0)
            let lag = watch.stop()
            let shellSecs = pane.session.blocks.last?.duration ?? secs
            let mb = label.hasPrefix("cat") ? Double(bytes) / 1_048_576 : 14.6
            note(String(format: "perf: %@ took %.2f s (shell says %.2f s, %.0f MB/s) · UI lag worst %.0f ms · p99 %.0f ms · freezes over 50 ms: %d",
                        label as NSString, secs, shellSecs, mb / max(shellSecs, 0.001), lag.max, lag.p99, lag.over50))
        }
        pane.run("clear # anser-selftest-perf")
        _ = await wait(10) { pane.session.atPrompt }

        // A new tab: until its prompt is ready.
        var opens: [Double] = []
        for _ in 0..<3 {
            let t0 = Date()
            wc.addTab(cwd: dir)
            let p = wc.focusedPane
            _ = await wait(20) { p?.session.atPrompt == true && p?.editorUsable == true }
            opens.append(Date().timeIntervalSince(t0) * 1000)
            await sleep(0.5)
        }
        note(String(format: "perf: new tab ready in %@ ms", opens.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        // Switching tabs: until the main thread is free again.
        var switches: [Double] = []
        for i in 0..<12 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            wc.selectTab(i % wc.tabs.count)
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.window?.displayIfNeeded()
            switches.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            await sleep(0.15)
        }
        note(String(format: "perf: tab switch avg %.1f ms · worst %.1f ms", switches.reduce(0, +) / Double(switches.count), switches.max() ?? 0))
        while wc.tabs.count > 1, let i = wc.tabs.firstIndex(where: { $0 !== wc.tab(for: pane) }) { wc.closeTab(i) }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

/// Times named pieces of work while the perf test types (off otherwise).
enum PerfProbe {
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var totals: [String: (ms: Double, n: Int)] = [:]

    @discardableResult
    static func time<T>(_ name: String, _ f: () -> T) -> T {
        guard enabled else { return f() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let r = f()
        let d = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let old = totals[name] ?? (0, 0)
        totals[name] = (old.ms + d, old.n + 1)
        return r
    }

    static func report() -> String {
        totals.sorted { $0.value.ms > $1.value.ms }.map { String(format: "%@ %.2f ms×%d", $0.key as NSString, $0.value.ms / Double(max($0.value.n, 1)), $0.value.n) }.joined(separator: " · ")
    }
}
