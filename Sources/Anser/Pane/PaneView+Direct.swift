import AppKit
import GhosttyKit

/// Kept tabs whose terminal Ghostty reads directly (see `DirectTerminal`).
extension PaneView {
    /// Off: kept tabs start through `anser-session attach` (tests of the fallback;
    /// `ANSER_DIRECT_TABS=0` for comparing the two).
    static var directKeptTabs = ProcessInfo.processInfo.environment["ANSER_DIRECT_TABS"] != "0"

    func watchDirect() {
        direct?.surface = { [weak self] in self?.surfaceView.surface }
        direct?.watch(onExit: { [weak self] status in
            // The surface closes the way it does when Ghostty's own child exits.
            guard let self, let s = self.surfaceView.surface, let direct = self.direct else { return }
            ghostty_surface_child_exited(s, UInt32(bitPattern: status), direct.runtimeMS)
        }, onElsewhere: { [weak self] _ in
            // Another window has the shell now: close this tab without ending it, and promptly,
            // so two tabs never read the same terminal.
            guard let self else { return }
            self.keepShellOnClose = true
            self.direct?.close()
            if let wc = self.windowController { wc.close(self) } else { self.teardown() }
        })
    }

    /// Lets go of the terminal before the surface closes. A kept shell gets the tab's recent
    /// output back in the helper, to show next time.
    func releaseDirect(keep: Bool) {
        guard let direct, !direct.closed else { return }
        var history: [UInt8]?
        if keep, let s = surfaceView.surface {
            var buf = [UInt8](repeating: 0, count: 2 << 20)
            let n = ghostty_surface_recent_output(s, &buf, buf.count)
            history = Array(buf[0..<n])
        }
        direct.close(handingBack: history)
    }
}
