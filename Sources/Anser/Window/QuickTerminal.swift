import AppKit
import Carbon.HIToolbox
import AnserCore

/// A terminal that drops down from the top of the screen when you press a
/// global shortcut (Settings → Sessions & Windows → Quick terminal), from any app.
/// Press the shortcut again to tuck it away and go back to the app you were in.
final class QuickTerminal {
    static let shared = QuickTerminal()

    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var hotKey: HotKey?
    private(set) var controller: TerminalWindowController?
    private var previousApp: NSRunningApplication?
    /// Why the shortcut couldn't be registered, if it couldn't.
    private(set) var problem: String?

    var isShown: Bool { controller?.window?.isVisible == true }

    /// Registers (or clears) the global shortcut, e.g. "ctrl+`".
    func configure(_ text: String?) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        hotKey = nil
        problem = nil
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let hk = HotKey.parse(text) else {
            problem = "“\(text)” isn't a shortcut Anser can use from other apps. Use a modifier with a key, like ctrl+` or alt+space."
            return
        }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x616E_7372), id: 1)   // "ansr"
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            problem = "\(hk.display) is already used by another app or macOS. Pick another shortcut."
            return
        }
        hotKeyRef = ref
        hotKey = hk
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { QuickTerminal.shared.toggle() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    func toggle() {
        if let w = controller?.window, w.isVisible, w.isKeyWindow, NSApp.isActive { hide() } else { show() }
    }

    func show() {
        Services.shared.record("quickTerminal.show")
        if let front = NSWorkspace.shared.frontmostApplication, front != .current { previousApp = front }
        if controller == nil || controller?.window == nil || controller?.tabs.isEmpty == true {
            let wc = TerminalWindowController(cwd: nil)
            wc.isQuickTerminal = true
            controller = wc
            AppDelegate.shared.adoptQuietly(wc)
        }
        guard let wc = controller, let w = wc.window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let share = min(0.9, max(0.2, Services.shared.config.quickTerminalHeight))
        let h = (vf.height * share).rounded()
        let target = NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        w.setFrame(NSRect(x: target.minX, y: vf.maxY, width: target.width, height: h), display: false)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil ? 0.16 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(target, display: true)
        }
        wc.focusedPane?.focus()
    }

    func hide() {
        guard let w = controller?.window, w.isVisible else { return }
        w.orderOut(nil)
        // Go back to where you were, unless another Anser window is in front.
        if let prev = previousApp, !prev.isTerminated,
           !NSApp.windows.contains(where: { $0 !== w && $0.isVisible && $0.windowController is TerminalWindowController && $0.isKeyWindow }) {
            prev.activate()
        }
        previousApp = nil
    }

    /// The window was closed (its last tab ended): start fresh next time.
    func windowClosed(_ wc: TerminalWindowController) {
        if wc === controller { controller = nil }
    }
}
