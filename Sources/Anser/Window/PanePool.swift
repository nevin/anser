import AppKit
import AnserCore

/// One shell started ahead of time, so a new tab or split shows its prompt at
/// once instead of after your shell's startup files run. When it's used, it
/// moves to the new tab's folder silently (through the hooks, so nothing is
/// typed or saved to history), and another one starts in the background.
@MainActor
final class PanePool {
    static let shared = PanePool()

    private var spare: PaneView?
    private var signature = ""
    private var refillWork: DispatchWorkItem?
    /// The self-test turns it on only for the checks that use it.
    static var enabledInSelfTest = false

    var isEnabled: Bool {
        Services.shared.config.prewarmShell && SessionHost.shared.enabled && SessionHost.shared.helperPath != nil
            && (!Services.isSelfTest || Self.enabledInSelfTest)
    }

    /// Settings a shell picks up when it starts: a spare started under others isn't used.
    private static var currentSignature: String {
        let c = Services.shared.config
        return [c.shellPrompt, c.commandSeparator, String(c.showLoginMessage), ShellSession.userShell].joined(separator: "|")
    }

    /// Ready to be used: at its first prompt, with Anser's hooks loaded.
    var isReady: Bool {
        guard let s = spare?.session else { return false }
        return s.atPrompt && s.integrated && s.capabilities.contains("load") && s.shellPID > 0 && !s.isRemote
    }

    func scheduleRefill(after delay: TimeInterval = 1.5) {
        refillWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refill() }
        refillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refill() {
        guard isEnabled, spare == nil, !AppDelegate.shared.isTerminating else { return }
        spare = PaneView(cwd: nil)
        signature = Self.currentSignature
    }

    /// The spare shell for a new pane in `cwd`, or nil to start one the usual way.
    func take(cwd: String?) -> PaneView? {
        guard isEnabled else { discard(); return nil }
        guard let p = spare, isReady else { return nil }
        guard signature == Self.currentSignature else { discard(); scheduleRefill(); return nil }
        if let cwd {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { return nil }
            // A folder profile can add environment to new tabs there: start those fresh.
            if let env = Profile.resolve(Services.shared.config.profiles, host: nil, cwd: cwd)?.env, !env.isEmpty { return nil }
        }
        spare = nil
        if let cwd, cwd != p.session.cwd {
            let shell = ProjectEnv.Shell(p.session.env.shell)
            _ = p.sendToShell((shell == .fish ? "cd " : "builtin cd -- ") + ProjectEnv.q(cwd, shell) + " 2>/dev/null\n")
            p.session.assumeCwd(cwd)
        }
        // The new folder's Node version, virtualenv and .env offer, right away rather than after the first command.
        p.checkProjectEnvironment()
        p.checkProjectRuntimes()
        Services.shared.record("tab.prewarmed")
        scheduleRefill()
        return p
    }

    /// Ends the spare shell (quitting, or a setting changed what shells start with).
    func discard() {
        refillWork?.cancel()
        refillWork = nil
        guard let p = spare else { return }
        spare = nil
        p.teardown()
    }

    /// For tests.
    var spareForTest: PaneView? { spare }
}
