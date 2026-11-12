import AppKit
import Carbon.HIToolbox
import GhosttyKit
import AnserCore

/// An NSView that hosts one libghostty terminal surface (GPU-rendered by
/// Ghostty itself) and forwards keyboard, mouse and IME input to it.
final class TerminalSurfaceView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    weak var pane: PaneView?
    var cellSize: CGSize = .zero

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?
    private var cursorShape: NSCursor = .iBeam

    static func from(_ ud: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let ud else { return nil }
        return Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    init(workingDirectory: String?, command: String?, env: [String: String]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        guard let app = GhosttyRuntime.shared.app else { return }

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // C strings must stay alive until ghostty_surface_new returns.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafeMutablePointer<CChar> { let p = strdup(s)!; owned.append(p); return p }

        if let wd = workingDirectory { cfg.working_directory = UnsafePointer(c(wd)) }
        if let command { cfg.command = UnsafePointer(c(command)) }
        var vars = env.map { ghostty_env_var_s(key: UnsafePointer(c($0.key)), value: UnsafePointer(c($0.value))) }
        vars.withUnsafeMutableBufferPointer { buf in
            cfg.env_vars = buf.baseAddress
            cfg.env_var_count = buf.count
            surface = ghostty_surface_new(app, &cfg)
        }
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL])
    }

    // Files dropped on the terminal: their paths (or, in an ssh tab, an offer to upload them).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(sender.draggingPasteboard)
        guard !urls.isEmpty, let pane else { return false }
        if pane.offerUpload(urls.map(\.path)) { return true }
        let text = urls.map { ShellLexer.escape($0.path) }.joined(separator: " ") + " "
        if pane.editorUsable { pane.editor.insertText(text, replacementRange: pane.editor.selectedRange()); pane.focus() } else { sendText(text) }
        return true
    }

    static func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Frees the terminal. The shell gets SIGHUP.
    func destroy() {
        guard let s = surface else { return }
        surface = nil
        ghostty_surface_free(s)
    }

    deinit { destroy() }

    // MARK: Geometry

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        updateScale()
        if let surface, let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidChangeScreen), name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func windowDidChangeScreen() {
        guard let surface, let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
        ghostty_surface_set_display_id(surface, id)
        updateScale()
    }

    /// Hidden tabs tell Ghostty they're not visible so it can stop drawing them.
    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible && (window?.occlusionState.contains(.visible) ?? true))
    }

    @objc private func occlusionChanged() {
        guard let surface, let window else { return }
        ghostty_surface_set_occlusion(surface, window.occlusionState.contains(.visible))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        guard let surface, let window else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        let fb = convertToBacking(bounds)
        let sx = bounds.width > 0 ? fb.width / bounds.width : window.backingScaleFactor
        let sy = bounds.height > 0 ? fb.height / bounds.height : window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, sx, sy)
        sendSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sendSize()
        pane?.surfaceDidResize()
    }

    private func sendSize() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let px = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(px.width), UInt32(px.height))
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        if ok { pane?.didFocus() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // At a prompt with the command editor on, typing belongs in the editor.
        if let pane, pane.redirectKeyToEditor(event) { return }
        guard let surface else { interpretKeyEvents([event]); return }
        pane?.noteRawTyping()

        // Which modifiers should be used to translate text (handles option-as-alt).
        let tm = ghostty_surface_key_translation_mods(surface, Self.mods(event.modifierFlags))
        var translationFlags = event.modifierFlags
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if tm.rawValue & bit.rawValue != 0 { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        let translationEvent: NSEvent
        if translationFlags == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type, location: event.locationInWindow, modifierFlags: translationFlags,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: translationFlags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let hadMarked = markedText.length > 0
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list { sendKey(event, action, translationFlags, text: text, composing: false) }
        } else {
            let composing = markedText.length > 0 || hadMarked
            sendKey(event, action, translationFlags, text: composing ? nil : Self.characters(translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, GHOSTTY_ACTION_RELEASE, event.modifierFlags, text: nil, composing: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: NSEvent.ModifierFlags
        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: mod = .shift
        case kVK_Control, kVK_RightControl: mod = .control
        case kVK_Option, kVK_RightOption: mod = .option
        case kVK_Command, kVK_RightCommand: mod = .command
        case kVK_CapsLock: mod = .capsLock
        default: return
        }
        let action = event.modifierFlags.contains(mod) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        sendKey(event, action, event.modifierFlags, text: nil, composing: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else { return false }
        // Control combos (ctrl+/ etc.) reach here before keyDown; send them to the terminal.
        if event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return false
    }

    private func sendKey(_ event: NSEvent, _ action: ghostty_input_action_e, _ translation: NSEvent.ModifierFlags, text: String?, composing: Bool) {
        guard let surface else { return }
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.mods = Self.mods(event.modifierFlags)
        k.consumed_mods = Self.mods(translation.subtracting([.control, .command]))
        k.composing = composing
        k.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.characters(byApplyingModifiers: []), let cp = chars.unicodeScalars.first {
            k.unshifted_codepoint = cp.value
        }
        if let text, !text.isEmpty {
            text.withCString { p in
                k.text = p
                _ = ghostty_surface_key(surface, k)
            }
        } else {
            k.text = nil
            _ = ghostty_surface_key(surface, k)
        }
    }

    /// Sends a synthetic key press+release (for Return, ctrl-c, etc.).
    func sendSyntheticKey(keyCode: Int, mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE, text: String?, unshifted: Character) {
        guard let surface else { return }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var k = ghostty_input_key_s()
            k.action = action
            k.keycode = UInt32(keyCode)
            k.mods = mods
            k.consumed_mods = GHOSTTY_MODS_NONE
            k.composing = false
            k.unshifted_codepoint = unshifted.unicodeScalars.first?.value ?? 0
            if action == GHOSTTY_ACTION_PRESS, let text {
                text.withCString { p in k.text = p; _ = ghostty_surface_key(surface, k) }
            } else {
                k.text = nil
                _ = ghostty_surface_key(surface, k)
            }
        }
    }

    /// Sends text as a paste (bracketed if the program asked for it).
    func sendText(_ text: String) {
        guard let surface else { return }
        let len = text.utf8.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(len)) }
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(m)
    }

    /// Text for a key event, without control characters or function-key codes.
    static func characters(_ event: NSEvent) -> String? {
        guard let chars = event.characters else { return nil }
        if chars.count == 1, let s = chars.unicodeScalars.first {
            if s.value < 0x20 { return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) }
            if s.value >= 0xF700 && s.value <= 0xF8FF { return nil }
        }
        return chars
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { cursorShape.set() }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursorShape = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursorShape = .iBeam
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursorShape = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursorShape = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursorShape = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: cursorShape = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursorShape = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursorShape = .resizeUpDown
        default: cursorShape = .arrow
        }
        DispatchQueue.main.async { [cursorShape] in cursorShape.set() }
    }

    private func sendPos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, p.x, bounds.height - p.y, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard let surface else { return }
        sendPos(event)
        // ⌘-click a file path (e.g. src/app.swift:42) to open it in your editor.
        if event.modifierFlags.contains(.command), let word = wordUnderMouse(), let pane, pane.openLink(word) { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
        // After selecting with the mouse at a prompt, go back to the editor
        // so typing still works; the selection stays copyable with Cmd-C.
        pane?.mouseFinishedInTerminal(hasSelection: ghostty_surface_has_selection(surface))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        if ghostty_surface_mouse_captured(surface) {
            sendPos(event)
            _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
            return
        }
        sendPos(event)
        let overlayPoint = pane?.blocksOverlay.convert(event.locationInWindow, from: nil)
        NSMenu.popUpContextMenu(contextMenu(at: overlayPoint), with: event, for: self)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface, ghostty_surface_mouse_captured(surface) else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event.modifierFlags))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, Self.mods(event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface, event.buttonNumber == 2 else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, Self.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        sendPos(event)
        if let o = pane?.blocksOverlay { o.hover(at: o.convert(event.locationInWindow, from: nil)) }
        // Quick Look a file path once the mouse rests on it.
        let point = convert(event.locationInWindow, from: nil)
        pane?.mouseMovedOverOutput(at: point)
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pane?.previewPathUnderMouse(at: point) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
    private var hoverWork: DispatchWorkItem?
    override func mouseDragged(with event: NSEvent) { sendPos(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPos(event) }
    override func mouseEntered(with event: NSEvent) { sendPos(event) }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        pane?.closePreview()
        // Moving onto the hover strip keeps it; leaving the terminal hides it.
        if let o = pane?.blocksOverlay, !o.stripContains(o.convert(event.locationInWindow, from: nil)) { o.hover(at: nil) }
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        var mods: Int32 = precise ? 1 : 0
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        mods |= momentum << 1
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    /// The right-click menu; `point` (in the blocks overlay) picks the command under the mouse.
    func contextMenu(at point: NSPoint? = nil) -> NSMenu {
        let m = NSMenu()
        // Right-clicked a command or its output: everything you can do with it.
        if let pane, let point, let items = pane.blocksOverlay.commandMenuItems(at: point), !items.isEmpty {
            items.forEach { m.addItem($0) }
            m.addItem(.separator())
        }
        // Right-clicked a file path in the output: open, preview, blame, reveal, copy.
        if let pane, let word = wordUnderMouse(), let link = pane.pathLink(word, viewport: viewportText()) {
            let name = (link.path as NSString).lastPathComponent
            let env = pane.session.env
            m.addItem(ClosureMenuItem(title: "Open “\(name)”") { [weak pane] in
                if !FileActions.openInEditor(link.path, env: env) { _ = pane?.openFile(link.line.map { "\(link.path):\($0)" } ?? link.path) }
            })
            m.addItem(ClosureMenuItem(title: "Quick Look") { FileActions.quickLook(link.path) })
            if !FileActions.isFolder(link.path), GitInfo.gitDir(for: (link.path as NSString).deletingLastPathComponent) != nil {
                m.addItem(ClosureMenuItem(title: link.line == nil ? "Blame" : "Blame Line \(link.line!)") { [weak pane] in
                    guard let pane else { return }
                    pane.windowController?.showBlame(for: pane, path: link.path, line: link.line)
                })
            }
            m.addItem(ClosureMenuItem(title: "Show in Finder") { FileActions.reveal(link.path) })
            m.addItem(ClosureMenuItem(title: "Copy Path") { FileActions.copyPath(link.path) })
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Copy Last Output", action: #selector(AppDelegate.copyLastOutput(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Copy Last Command", action: #selector(AppDelegate.copyLastCommand(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Search…", action: #selector(AppDelegate.historySearch(_:)), keyEquivalent: "")
        m.addItem(ClosureMenuItem(title: "Search All Tabs…") { [weak pane] in
            guard let pane else { return }
            pane.windowController?.showSearchAllTabs(for: pane)
        })
        m.addItem(.separator())
        let split = NSMenuItem(title: "Split", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        sm.addItem(withTitle: "Split Right", action: #selector(AppDelegate.splitRight(_:)), keyEquivalent: "")
        sm.addItem(withTitle: "Split Down", action: #selector(AppDelegate.splitDown(_:)), keyEquivalent: "")
        sm.addItem(ClosureMenuItem(title: "Split Left") { [weak pane] in if let pane { pane.windowController?.split(pane, vertical: true, before: true) } })
        sm.addItem(ClosureMenuItem(title: "Split Up") { [weak pane] in if let pane { pane.windowController?.split(pane, vertical: false, before: true) } })
        split.submenu = sm
        split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        m.addItem(split)
        m.addItem(.separator())
        m.addItem(withTitle: "Clear", action: #selector(AppDelegate.clearScreen(_:)), keyEquivalent: "")
        m.addItem(ClosureMenuItem(title: "Deep Clean…") { [weak pane] in pane?.confirmDeepClean() })
        return m
    }

    // MARK: Edit actions

    @discardableResult
    func binding(_ action: String) -> Bool {
        guard let surface else { return false }
        let len = action.utf8.count
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(len)) }
    }

    var hasSelection: Bool { surface.map { ghostty_surface_has_selection($0) } ?? false }

    @objc func copy(_ sender: Any?) {
        if let surface, ghostty_surface_has_selection(surface) { Services.shared.tip(in: pane) { $0.mouseCopy() } }
        binding("copy_to_clipboard")
    }
    @objc func paste(_ sender: Any?) {
        if let pane, pane.pasteIntoEditorIfAtPrompt() { return }
        binding("paste_from_clipboard")
    }
    @objc override func selectAll(_ sender: Any?) { binding("select_all") }

    func selectionText() -> String? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(data: Data(bytes: p, count: Int(t.text_len)), encoding: .utf8)
    }

    /// The word under the mouse (Ghostty's own word boundaries).
    func wordUnderMouse() -> String? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_quicklook_word(surface, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(data: Data(bytes: p, count: Int(t.text_len)), encoding: .utf8)
    }

    /// Text of one visible row (0 = top of the screen).
    func rowText(_ row: Int) -> String? {
        guard let surface, row >= 0 else { return nil }
        let size = ghostty_surface_size(surface)
        guard row < Int(size.rows) else { return nil }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(max(0, Int(size.columns) - 1)), y: UInt32(row)),
            rectangle: false)
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(data: Data(bytes: p, count: Int(t.text_len)), encoding: .utf8)
    }

    /// Visible prompt marks (newest first by index).
    func promptMarks() -> [ghostty_prompt_mark_s] {
        guard let surface else { return [] }
        var buf = [ghostty_prompt_mark_s](repeating: ghostty_prompt_mark_s(), count: 256)
        let n = ghostty_surface_prompt_marks(surface, &buf, 256)
        return Array(buf.prefix(n))
    }

    /// Text on the rows where a prompt mark sits (a few rows, for multi-line prompts).
    func promptText(_ m: ghostty_prompt_mark_s) -> String {
        let row = Int((m.y / max(m.height, 1)).rounded(.down))
        return (row..<(row + 3)).compactMap { rowText($0) }.joined(separator: "\n")
    }

    /// The visible screen as text.
    func viewportText() -> String? {
        guard let surface else { return nil }
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(data: Data(bytes: p, count: Int(t.text_len)), encoding: .utf8)
    }

    /// Output of a recent command (0 = most recent), from Ghostty's prompt marks.
    func commandOutput(index: Int) -> String? {
        guard let surface else { return nil }
        var t = ghostty_text_s()
        guard ghostty_surface_read_command_output(surface, UInt32(index), &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let p = t.text else { return nil }
        return String(data: Data(bytes: p, count: Int(t.text_len)), encoding: .utf8).map(CommandSeparator.strip)
    }

    // MARK: NSTextInputClient (IME)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(s)
        } else {
            sendText(s) // e.g. emoji picker or dictation
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString(string: s)
        guard let surface else { return }
        let len = s.utf8.count
        s.withCString { ghostty_surface_preedit(surface, $0, UInt(len)) }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let local = NSRect(x: x, y: bounds.height - y, width: max(w, 1), height: max(h, 1))
        return window.convertToScreen(convert(local, to: nil))
    }

    override func doCommand(by selector: Selector) {
        // Handled by Ghostty's own key encoding; don't beep.
    }
}
