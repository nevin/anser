import AppKit
import Darwin
import AnserCore
import IOSurface
import QuartzCore

/// Resource use of the live app (scripts/profile.sh): memory, CPU, GPU and
/// wakeups while idle with one and many tabs, after output, and minimized.
extension SelfTest {
    struct Usage {
        var cpuNs: UInt64, gpuNs: UInt64, wakeups: UInt64, footprint: UInt64
        static func now() -> Usage {
            var info = task_power_info_v2_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count) }
            }
            var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
            let cpu = (info.cpu_energy.total_user + info.cpu_energy.total_system) * UInt64(tb.numer) / UInt64(tb.denom)
            return Usage(cpuNs: cpu, gpuNs: info.gpu_energy.task_gpu_utilisation,
                         wakeups: info.cpu_energy.task_interrupt_wakeups + info.cpu_energy.task_platform_idle_wakeups,
                         footprint: MemoryUse.footprint().current)
        }
    }

    /// Idle for `seconds`, then one INFO line: CPU %, GPU ms/s, wakeups/s, memory.
    @MainActor
    static func measureIdle(_ label: String, seconds: Double = 10) async {
        let a = Usage.now()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let b = Usage.now()
        note(String(format: "%-34@ cpu %5.2f%%  gpu %6.2f ms/s  wakeups %5.1f/s  memory %4.0f MB", label as NSString,
                    Double(b.cpuNs - a.cpuNs) / (seconds * 1e7), Double(b.gpuNs - a.gpuNs) / (seconds * 1e6),
                    Double(b.wakeups - a.wakeups) / seconds, Double(b.footprint) / 1_048_576))
    }

    @MainActor
    static func profileChecks(_ pane: PaneView, _ wc: TerminalWindowController) async {
        _ = await profileWait(30) { pane.session.atPrompt }
        try? await Task.sleep(nanoseconds: 5_000_000_000)   // let startup work (spare shell, indexes) settle
        note("window visible to macOS: \(wc.window?.occlusionState.contains(.visible) ?? false), frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        await measureIdle("1 tab, idle")

        let dir = NSTemporaryDirectory() + "anser-selftest-profile"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for _ in 0..<9 { wc.addTab(cwd: dir) }
        let all = { wc.tabs.indices.compactMap { wc.panes(inTab: $0).first } }
        _ = await profileWait(60) { all().allSatisfy { $0.session.atPrompt } }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await measureIdle("10 tabs, idle")

        // Output in every tab: ~2.5 MB each (scrollback, kept output, blocks).
        let before = Usage.now()
        for p in all() { p.run("seq 1 400000 # anser-selftest") }
        _ = await profileWait(120) { all().allSatisfy { $0.session.atPrompt && $0.session.blocks.last?.command.hasPrefix("seq") == true } }
        let after = Usage.now()
        note(String(format: "10 × 2.5 MB of output              cpu %.2f s  gpu %.0f ms  memory +%.0f MB",
                    Double(after.cpuNs - before.cpuNs) / 1e9, Double(after.gpuNs - before.gpuNs) / 1e6,
                    (Double(after.footprint) - Double(before.footprint)) / 1_048_576))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await measureIdle("10 tabs with output, idle")
        footprintNote("10 tabs with output")
        try? await Task.sleep(nanoseconds: UInt64(TerminalSurfaceView.frameDropDelay * 1e9))
        footprintNote("10 tabs, hidden ones idle \(Int(TerminalSurfaceView.frameDropDelay))s")
        // Showing a tab whose frame was dropped: how soon it draws again.
        let back = (wc.selectedIndex + 1) % wc.tabs.count
        let shown = wc.panes(inTab: back).first
        let t0 = Date()
        wc.window?.orderFrontRegardless()
        wc.selectTab(back)
        let drew = await profileWait(2) { shown?.surfaceView.layer?.contents != nil }
        note(String(format: "switching to a tab hidden a while: first frame in %.0f ms%@", Date().timeIntervalSince(t0) * 1000, drew ? "" : " (no frame!)"))
        if wc.window?.occlusionState.contains(.visible) != true {
            note("skipped the redraw check: the window isn't visible (screen locked or covered)")
        } else if drew { pass("a tab hidden a while draws again when shown") } else { fail("a tab hidden a while draws again when shown") }

        // A long-running command that prints nothing (a server waiting), in the visible tab.
        let visible = wc.panes(inTab: wc.selectedIndex).first
        visible?.run("sleep 30 # anser-selftest")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await measureIdle("command running, no output")
        visible?.sendControl("c")
        _ = await profileWait(10) { visible?.session.atPrompt ?? true }

        wc.window?.miniaturize(nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await measureIdle("minimized")
        wc.window?.deminiaturize(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        NSApp.hide(nil)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await measureIdle("app hidden")
        NSApp.unhide(nil)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        final class Weak { weak var pane: PaneView?; weak var session: ShellSession?; weak var surface: NSView? }
        let closing: [Weak] = all().dropFirst().map { p in let w = Weak(); w.pane = p; w.session = p.session; w.surface = p.surfaceView; return w }
        while wc.tabs.count > 1 { wc.closeTab(wc.tabs.count - 1) }
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        note("closed tabs still in memory: panes \(closing.filter { $0.pane != nil }.count)/9, sessions \(closing.filter { $0.session != nil }.count)/9, terminal views \(closing.filter { $0.surface != nil }.count)/9")
        await measureIdle("back to 1 tab")
        note(String(format: "after returning freed memory: %.0f MB", { MemoryUse.releaseFreed(); return Double(MemoryUse.footprint().current) / 1_048_576 }()))
        try? FileManager.default.removeItem(atPath: dir)
        pass("profile finished")
    }

    /// The biggest kinds of memory, from footprint(1).
    static func footprintNote(_ label: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        p.arguments = [String(getpid())]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let rows = text.split(separator: "\n").filter { $0.contains(" MB ") || $0.contains("phys_footprint") }.prefix(10)
        note("footprint, \(label):\n      " + rows.joined(separator: "\n      "))
        // IOSurfaces by size, to tell frame buffers from view backings.
        let v = Process(); v.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        v.arguments = ["-w", String(getpid())]
        let vp = Pipe(); v.standardOutput = vp; v.standardError = Pipe()
        guard (try? v.run()) != nil else { return }
        let vt = String(decoding: vp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        v.waitUntilExit()
        var sizes: [String: Int] = [:]
        for line in vt.split(separator: "\n") where line.hasPrefix("IOSurface") {
            if let m = line.range(of: #"\[ *([0-9.]+[KMG])"#, options: .regularExpression) { sizes[String(line[m]).replacingOccurrences(of: "[", with: "").trimmingCharacters(in: .whitespaces), default: 0] += 1 }
        }
        note("IOSurfaces by size: " + sizes.sorted { $0.value > $1.value }.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
    }

    @MainActor
    private static func profileWait(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let start = Date()
        while !cond() {
            if Date().timeIntervalSince(start) > timeout { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }
}
