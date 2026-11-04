import AppKit
import Carbon.HIToolbox
import GhosttyKit
import AnserCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate!

    private var windows: [TerminalWindowController] = []
    private var keyMonitor: Any?
    private var keybindings: [String: String] = [:]
    private(set) var isActive = true
    private(set) var isTerminating = false
    private var configWatcher: DispatchSourceFileSystemObject?

    /// Shortcut text shown next to actions in the command palette.
    private(set) var shortcutLabels: [AnserAction: String] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.start()
        Services.shared.start()
        guard GhosttyRuntime.shared.start() else {
            let a = NSAlert()
            a.messageText = "Anser couldn't start the terminal engine"
            a.informativeText = "libghostty failed to initialize. Check Console.app for details."
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        loadKeybindings()
        installKeyMonitor()
        watchConfig()
        let selfTest = ProcessInfo.processInfo.environment["ANSER_SELFTEST"] != nil
        let restored = !selfTest && Services.shared.config.restoreSession && restoreSession()
        if !restored { newWindow(cwd: nil) }
        if !selfTest, !UserDefaults.standard.bool(forKey: "AnserWelcomeShown") { currentPane?.showWelcome() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerCrashReport() }
        NSApp.activate(ignoringOtherApps: true)
        if let err = Services.shared.configError { showConfigError(err) }
        SelfTest.runIfRequested()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        isActive = true
        if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        isActive = false
        if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = windows.flatMap(\.allPanesEverywhere).filter(\.hasRunningProcess)
        if busy.isEmpty || ProcessInfo.processInfo.environment["ANSER_SELFTEST"] != nil { isTerminating = true; return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit Anser?"
        a.informativeText = "These are still running and will be stopped:\n" + busy.map(\.runningDescription).prefix(8).joined(separator: "\n")
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { isTerminating = true; return .terminateNow }
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil { saveSession() }
    }

    // MARK: Session restore

    private struct SavedWindow: Codable {
        var frame: String
        var tabs: [TerminalWindowController.SavedTab]
        var selected: Int?
    }

    private var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Anser/session.json")
    }

    private func saveSession() {
        var saved: [SavedWindow] = []
        for wc in windows {
            guard let w = wc.window else { continue }
            let tabs = wc.snapshotTabs()
            if !tabs.isEmpty { saved.append(SavedWindow(frame: NSStringFromRect(w.frame), tabs: tabs, selected: wc.selectedIndex)) }
        }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: sessionURL) }
    }

    private func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: sessionURL),
              let saved = try? JSONDecoder().decode([SavedWindow].self, from: data), !saved.isEmpty else { return false }
        for sw in saved {
            let wc = TerminalWindowController(tabs: sw.tabs, selected: sw.selected ?? 0, frame: NSRectFromString(sw.frame))
            windows.append(wc)
            wc.showWindow(nil)
            wc.window?.makeKeyAndOrderFront(nil)
        }
        currentController?.focusedPane?.focus()
        return !windows.isEmpty
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(cwd: nil) }
        return true
    }

    // MARK: Windows

    var currentController: TerminalWindowController? {
        if let wc = NSApp.keyWindow?.windowController as? TerminalWindowController { return wc }
        if let parent = NSApp.keyWindow?.parent, let wc = parent.windowController as? TerminalWindowController { return wc }
        return NSApp.mainWindow?.windowController as? TerminalWindowController ?? windows.last
    }

    var currentPane: PaneView? { currentController?.focusedPane ?? currentController?.allPanes.first }

    func newWindow(cwd: String?) {
        let wc = TerminalWindowController(cwd: cwd)
        windows.append(wc)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.focusedPane?.focus()
    }

    func newTab(from pane: PaneView?) {
        guard let wc = pane?.windowController ?? currentController else { newWindow(cwd: pane?.session.cwd); return }
        wc.addTab(cwd: pane?.session.cwd ?? wc.focusedPane?.session.cwd)
    }

    func windowClosed(_ wc: TerminalWindowController) {
        windows.removeAll { $0 === wc }
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, for qa: AnserAction? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            if let qa, !key.isEmpty { shortcutLabels[qa] = Self.label(key: key, mods: mods) }
            return i
        }

        // App
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(item("About Anser", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openSettings(_:)), ",", for: .openSettings))
        app.addItem(item("Open Config File", #selector(openConfig(_:)), ",", [.command, .option], for: .openConfig))
        app.addItem(item("Reload Config", #selector(reloadConfig(_:)), ",", [.command, .shift], for: .reloadConfig))
        app.addItem(.separator())
        app.addItem(item("Hide Anser", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(.separator())
        app.addItem(item("Quit Anser", #selector(NSApplication.terminate(_:)), "q"))
        appItem.submenu = app
        main.addItem(appItem)

        // Shell
        let shellItem = NSMenuItem()
        let shell = NSMenu(title: "Shell")
        shell.addItem(item("New Window", #selector(newWindowAction(_:)), "n", for: .newWindow))
        shell.addItem(item("New Tab", #selector(newTabAction(_:)), "t", for: .newTab))
        shell.addItem(.separator())
        shell.addItem(item("Split Right", #selector(splitRight(_:)), "d", for: .splitRight))
        shell.addItem(item("Split Down", #selector(splitDown(_:)), "d", [.command, .shift], for: .splitDown))
        shell.addItem(.separator())
        shell.addItem(item("Re-run Last Command", #selector(rerunLast(_:)), "r", [.command, .shift], for: .rerunLastCommand))
        shell.addItem(item("Run Workflow…", #selector(runWorkflow(_:)), "r", [.command, .option], for: .runWorkflow))
        shell.addItem(item("Ask Claude for a Command…", #selector(askClaude(_:)), "i", for: .askClaude))
        shell.addItem(item("Explain Last Error with Claude", #selector(explainError(_:)), "i", [.command, .option], for: .explainError))
        shell.addItem(item("Save Commands as Workflow…", #selector(saveWorkflow(_:)), "", for: .saveWorkflow))
        shell.addItem(.separator())
        shell.addItem(item("Export Tab as Markdown…", #selector(exportMarkdown(_:)), "s", [.command, .shift], for: .exportMarkdown))
        shell.addItem(item("Copy Tab as Markdown", #selector(copyMarkdown(_:)), "", for: .copyMarkdown))
        shell.addItem(item("Toggle Command Editor", #selector(toggleEditor(_:)), "e", for: .toggleEditor))
        shell.addItem(item("Expand Command Editor", #selector(toggleExpandedEditor(_:)), "e", [.command, .shift], for: .expandEditor))
        shell.addItem(item("Split / Join Command Lines", #selector(formatCommand(_:)), "f", [.command, .option], for: .formatCommand))
        shell.addItem(item("Edit Command in $EDITOR", #selector(editExternally(_:)), "e", [.command, .option], for: .externalEditor))
        shell.addItem(.separator())
        shell.addItem(item("Close", #selector(closePane(_:)), "w", for: .closePane))
        shellItem.submenu = shell
        main.addItem(shellItem)

        // Edit
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Copy Last Output", #selector(copyLastOutput(_:)), "c", [.command, .shift], for: .copyLastOutput))
        edit.addItem(item("Copy Last Command", #selector(copyLastCommand(_:)), "c", [.command, .option], for: .copyLastCommand))
        edit.addItem(item("Clipboard History…", #selector(clipboardHistory(_:)), "v", [.command, .shift], for: .clipboardHistory))
        edit.addItem(.separator())
        edit.addItem(item("Find…", #selector(findInTerminal(_:)), "f", for: .findInTerminal))
        edit.addItem(item("Pause History for This Tab", #selector(pauseHistory(_:)), "", for: .pauseHistory))
        editItem.submenu = edit
        main.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(item("Bigger", #selector(fontBigger(_:)), "=", for: .increaseFontSize))
        view.addItem(item("Smaller", #selector(fontSmaller(_:)), "-", for: .decreaseFontSize))
        view.addItem(item("Actual Size", #selector(fontReset(_:)), "0", for: .resetFontSize))
        view.addItem(.separator())
        view.addItem(item("Toggle Sidebar", #selector(toggleSidebar(_:)), "s", [.command, .control], for: .toggleSidebar))
        view.addItem(.separator())
        view.addItem(item("Clear Screen", #selector(clearScreen(_:)), "k", for: .clearScreen))
        view.addItem(item("Jump to Previous Prompt", #selector(jumpPrev(_:)), String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), for: .jumpToPreviousPrompt))
        view.addItem(item("Jump to Next Prompt", #selector(jumpNext(_:)), String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), for: .jumpToNextPrompt))
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        viewItem.submenu = view
        main.addItem(viewItem)

        // Go
        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        go.addItem(item("Search History…", #selector(historySearch(_:)), "r", for: .historySearch))
        go.addItem(item("Command Palette…", #selector(commandPalette(_:)), "p", [.command, .shift], for: .commandPalette))
        go.addItem(item("Commands in This Tab…", #selector(blockNavigator(_:)), "b", for: .blockNavigator))
        go.addItem(item("Jump to Folder…", #selector(jumpToFolder(_:)), "j", for: .jumpToFolder))
        go.addItem(.separator())
        go.addItem(item("Switch Branch…", #selector(switchBranch(_:)), "b", [.command, .shift], for: .switchBranch))
        go.addItem(item("Changed Files…", #selector(changedFiles(_:)), "g", [.command, .shift], for: .changedFiles))
        go.addItem(.separator())
        go.addItem(item("Next Pane", #selector(nextPane(_:)), "]", for: .focusNextPane))
        go.addItem(item("Previous Pane", #selector(prevPane(_:)), "[", for: .focusPreviousPane))
        go.addItem(item("Zoom Pane", #selector(zoomPane(_:)), "\r", [.command, .shift], for: .zoomPane))
        goItem.submenu = go
        main.addItem(goItem)

        // Window
        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        win.addItem(.separator())
        win.addItem(item("Show Previous Tab", #selector(prevTab(_:)), "[", [.command, .shift], for: .previousTab))
        win.addItem(item("Show Next Tab", #selector(nextTab(_:)), "]", [.command, .shift], for: .nextTab))
        win.addItem(item("Rename Tab…", #selector(renameTab(_:)), "i", [.command, .shift], for: .renameTab))
        win.addItem(item("Move Tab Left", #selector(moveTabLeft(_:)), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option], for: .moveTabLeft))
        win.addItem(item("Move Tab Right", #selector(moveTabRight(_:)), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option], for: .moveTabRight))
        win.addItem(item("Move Tab to New Window", #selector(moveTabToNewWindow(_:)), "", for: .moveTabToNewWindow))
        win.addItem(item("Close Tab", #selector(closeTab(_:)), "w", [.command, .shift], for: .closeTab))
        for n in 1...9 {
            let it = item("Tab \(n)", #selector(selectTabN(_:)), "\(n)")
            it.tag = n
            it.isAlternate = false
            win.addItem(it)
        }
        win.addItem(.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        let helpItem = NSMenuItem()
        let help = NSMenu(title: "Help")
        help.addItem(item("Keyboard Shortcuts", #selector(showShortcuts(_:)), "/", for: .showShortcuts))
        help.addItem(item("Show Welcome Tips", #selector(showWelcomeTips(_:))))
        help.addItem(.separator())
        help.addItem(item("Report a Problem…", #selector(reportProblem(_:))))
        help.addItem(item("Show Logs in Finder", #selector(showLogs(_:))))
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    static func label(key: String, mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        switch key {
        case String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): s += "↑"
        case String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): s += "↓"
        case String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): s += "←"
        case String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): s += "→"
        default: s += key.uppercased()
        }
        return s
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleEditor(_:)) {
            menuItem.state = (currentPane?.editorEnabled ?? true) ? .on : .off
        }
        if menuItem.action == #selector(toggleExpandedEditor(_:)) {
            menuItem.state = (currentPane?.editorExpanded ?? false) ? .on : .off
        }
        if menuItem.action == #selector(pauseHistory(_:)) {
            menuItem.state = (currentPane?.session.historyPaused ?? false) ? .on : .off
        }
        return true
    }

    // MARK: Actions (menu, palette, keybindings)

    @objc func newWindowAction(_ s: Any?) { newWindow(cwd: currentPane?.session.cwd) }
    @objc func newTabAction(_ s: Any?) { newTab(from: currentPane) }
    @objc func splitRight(_ s: Any?) { if let p = currentPane { currentController?.split(p, vertical: true) } }
    @objc func splitDown(_ s: Any?) { if let p = currentPane { currentController?.split(p, vertical: false) } }
    @objc func closePane(_ s: Any?) {
        if let picker = NSApp.keyWindow as? PickerPanel { picker.close(); return }
        if let p = currentPane { currentController?.closeAsking(p) } else { NSApp.keyWindow?.performClose(nil) }
    }
    @objc func nextPane(_ s: Any?) { if let p = currentPane { currentController?.focusPane(relativeTo: p, forward: true) } }
    @objc func prevPane(_ s: Any?) { if let p = currentPane { currentController?.focusPane(relativeTo: p, forward: false) } }
    @objc func toggleEditor(_ s: Any?) { currentPane?.toggleEditor() }
    @objc func clearScreen(_ s: Any?) { currentPane?.clearScreen() }
    @objc func jumpPrev(_ s: Any?) { currentPane?.surfaceView.binding("jump_to_prompt:-1") }
    @objc func jumpNext(_ s: Any?) { currentPane?.surfaceView.binding("jump_to_prompt:1") }
    @objc func fontBigger(_ s: Any?) { currentPane?.surfaceView.binding("increase_font_size:1") }
    @objc func fontSmaller(_ s: Any?) { currentPane?.surfaceView.binding("decrease_font_size:1") }
    @objc func fontReset(_ s: Any?) { currentPane?.surfaceView.binding("reset_font_size") }

    @objc func findInTerminal(_ s: Any?) { currentPane?.showFind() }
    @objc func jumpToFolder(_ s: Any?) { if let p = currentPane { currentController?.showFolderJumper(for: p) } }
    @objc func switchBranch(_ s: Any?) { if let p = currentPane { currentController?.showBranchSwitcher(for: p) } }
    @objc func changedFiles(_ s: Any?) { if let p = currentPane { currentController?.showChanges(for: p) } }
    @objc func showShortcuts(_ s: Any?) { ShortcutsPanel.toggle(over: currentController?.window) }
    @objc func showWelcomeTips(_ s: Any?) { currentPane?.showWelcome() }
    @objc func reportProblem(_ s: Any?) { ReportProblemWindowController.shared.show() }
    @objc func askClaude(_ s: Any?) { currentPane?.askClaude() }
    @objc func explainError(_ s: Any?) { currentPane?.explainLastError() }
    @objc func runWorkflow(_ s: Any?) { if let p = currentPane { currentController?.showWorkflows(for: p) } }
    @objc func saveWorkflow(_ s: Any?) { if let p = currentPane { currentController?.showSaveWorkflow(for: p) } }
    @objc func exportMarkdown(_ s: Any?) { if let p = currentPane { currentController?.exportMarkdown(for: p, copy: false) } }
    @objc func copyMarkdown(_ s: Any?) { if let p = currentPane { currentController?.exportMarkdown(for: p, copy: true) } }
    @objc func showLogs(_ s: Any?) { NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL]) }

    /// After a crash, offer to put together a report.
    private func offerCrashReport() {
        guard let crash = Diagnostics.shared.previousCrash, ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil else { return }
        Diagnostics.shared.log("Previous run crashed: \(crash.lastPathComponent)")
        let a = NSAlert()
        a.messageText = "Anser quit unexpectedly last time"
        a.informativeText = "A crash log was saved on this Mac. You can review it and copy a report to share."
        a.addButton(withTitle: "Review Report…")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { ReportProblemWindowController.shared.show(crashed: true) }
    }
    @objc func nextTab(_ s: Any?) { currentController?.selectNextTab(true) }
    @objc func toggleSidebar(_ s: Any?) { currentController?.toggleSidebar() }
    @objc func zoomPane(_ s: Any?) { if let p = currentPane { currentController?.toggleZoom(p) } }
    @objc func moveTabLeft(_ s: Any?) { currentController?.moveSelectedTab(by: -1) }
    @objc func moveTabRight(_ s: Any?) { currentController?.moveSelectedTab(by: 1) }
    @objc func moveTabToNewWindow(_ s: Any?) { if let c = currentController { c.moveTabToNewWindow(c.selectedIndex) } }

    /// Registers and shows a window created from another window's tab.
    func adopt(_ wc: TerminalWindowController) {
        windows.append(wc)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.focusedPane?.focus()
    }
    @objc func prevTab(_ s: Any?) { currentController?.selectNextTab(false) }
    @objc func renameTab(_ s: Any?) { currentController?.beginRenamingSelectedTab() }
    @objc func closeTab(_ s: Any?) { if let c = currentController { c.closeTabAsking(c.selectedIndex) } }
    @objc func selectTabN(_ s: NSMenuItem) {
        guard let c = currentController else { return }
        // ⌘9 always means the last tab, like browsers.
        c.selectTab(s.tag == 9 ? c.tabs.count - 1 : s.tag - 1)
    }
    @objc func toggleExpandedEditor(_ s: Any?) { currentPane?.toggleExpanded() }
    @objc func formatCommand(_ s: Any?) { currentPane?.formatCommand() }
    @objc func editExternally(_ s: Any?) { currentPane?.editInExternalEditor() }

    @objc func blockNavigator(_ s: Any?) {
        guard let p = currentPane else { return }
        currentController?.showBlocks(for: p)
    }

    @objc func pauseHistory(_ s: Any?) {
        guard let p = currentPane else { return }
        p.session.historyPaused.toggle()
        p.historyPausedChanged()
    }

    @objc func openSettings(_ s: Any?) { SettingsWindowController.shared.show() }

    @objc func historySearch(_ s: Any?) {
        guard let p = currentPane else { return }
        currentController?.showHistorySearch(for: p)
    }

    @objc func clipboardHistory(_ s: Any?) {
        guard let p = currentPane else { return }
        currentController?.showClipboardHistory(for: p)
    }

    @objc func commandPalette(_ s: Any?) {
        guard let p = currentPane else { return }
        currentController?.showCommandPalette(for: p)
    }

    @objc func copyLastOutput(_ s: Any?) {
        guard let p = currentPane else { return }
        if let out = p.lastOutput(), !out.isEmpty {
            TerminalWindowController.copy(out)
            flash(p, "Copied output (\(out.components(separatedBy: "\n").count) lines)")
        } else {
            NSSound.beep()
            flash(p, "The last command printed nothing to copy")
        }
    }

    @objc func copyLastCommand(_ s: Any?) {
        guard let p = currentPane, let cmd = p.lastCommand() else { NSSound.beep(); return }
        TerminalWindowController.copy(cmd)
        flash(p, "Copied command")
    }

    @objc func rerunLast(_ s: Any?) {
        guard let p = currentPane, let cmd = p.session.blocks.last?.command, p.session.atPrompt else { NSSound.beep(); return }
        p.run(cmd)
    }

    @objc func openConfig(_ s: Any?) {
        _ = AnserConfig.load() // makes sure the file exists
        NSWorkspace.shared.open(AnserConfig.fileURL)
    }

    @objc func reloadConfig(_ s: Any?) {
        Services.shared.loadConfig()
        loadKeybindings()
        GhosttyRuntime.shared.reloadConfig()
        if let err = Services.shared.configError { showConfigError(err) }
    }

    func perform(_ a: AnserAction, pane: PaneView) {
        switch a {
        case .historySearch: currentController?.showHistorySearch(for: pane)
        case .clipboardHistory: currentController?.showClipboardHistory(for: pane)
        case .commandPalette: currentController?.showCommandPalette(for: pane)
        case .copyLastOutput: copyLastOutput(nil)
        case .copyLastCommand: copyLastCommand(nil)
        case .newTab: newTab(from: pane)
        case .newWindow: newWindow(cwd: pane.session.cwd)
        case .splitRight: pane.windowController?.split(pane, vertical: true)
        case .splitDown: pane.windowController?.split(pane, vertical: false)
        case .closePane: pane.windowController?.closeAsking(pane)
        case .focusNextPane: pane.windowController?.focusPane(relativeTo: pane, forward: true)
        case .focusPreviousPane: pane.windowController?.focusPane(relativeTo: pane, forward: false)
        case .clearScreen: pane.clearScreen()
        case .toggleEditor: pane.toggleEditor()
        case .rerunLastCommand: rerunLast(nil)
        case .openConfig: openConfig(nil)
        case .reloadConfig: reloadConfig(nil)
        case .jumpToPreviousPrompt: pane.surfaceView.binding("jump_to_prompt:-1")
        case .jumpToNextPrompt: pane.surfaceView.binding("jump_to_prompt:1")
        case .increaseFontSize: pane.surfaceView.binding("increase_font_size:1")
        case .decreaseFontSize: pane.surfaceView.binding("decrease_font_size:1")
        case .resetFontSize: pane.surfaceView.binding("reset_font_size")
        case .findInTerminal: pane.showFind()
        case .blockNavigator: currentController?.showBlocks(for: pane)
        case .pauseHistory: pane.session.historyPaused.toggle(); pane.historyPausedChanged()
        case .openSettings: openSettings(nil)
        case .jumpToFolder: currentController?.showFolderJumper(for: pane)
        case .switchBranch: currentController?.showBranchSwitcher(for: pane)
        case .changedFiles: currentController?.showChanges(for: pane)
        case .showShortcuts: showShortcuts(nil)
        case .askClaude: pane.askClaude()
        case .explainError: pane.explainLastError()
        case .runWorkflow: currentController?.showWorkflows(for: pane)
        case .saveWorkflow: currentController?.showSaveWorkflow(for: pane)
        case .exportMarkdown: currentController?.exportMarkdown(for: pane, copy: false)
        case .copyMarkdown: currentController?.exportMarkdown(for: pane, copy: true)
        case .reportProblem: ReportProblemWindowController.shared.show()
        case .zoomPane: currentController?.toggleZoom(pane)
        case .toggleSidebar: currentController?.toggleSidebar()
        case .moveTabLeft: currentController?.moveSelectedTab(by: -1)
        case .moveTabRight: currentController?.moveSelectedTab(by: 1)
        case .moveTabToNewWindow: if let c = currentController { c.moveTabToNewWindow(c.selectedIndex) }
        case .renameTab: currentController?.beginRenamingSelectedTab()
        case .nextTab: currentController?.selectNextTab(true)
        case .previousTab: currentController?.selectNextTab(false)
        case .closeTab: closeTab(nil)
        case .expandEditor: pane.toggleExpanded()
        case .formatCommand: pane.formatCommand()
        case .externalEditor: pane.editInExternalEditor()
        }
    }

    // MARK: Feedback

    func flash(_ pane: PaneView, _ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        label.layer?.cornerRadius = 6
        label.sizeToFit()
        let w = label.frame.width + 24, h: CGFloat = 26
        label.frame = NSRect(x: pane.bounds.midX - w / 2, y: pane.bounds.height - h - 16, width: w, height: h)
        pane.addSubview(label)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; label.animator().alphaValue = 0 }, completionHandler: { label.removeFromSuperview() })
            }
        })
    }

    private func showConfigError(_ err: String) {
        let a = NSAlert()
        a.messageText = "There's a problem in your Anser config"
        a.informativeText = err + "\n\nAnser is using default settings until it's fixed."
        a.addButton(withTitle: "Open Config")
        a.addButton(withTitle: "OK")
        if a.runModal() == .alertFirstButtonReturn { openConfig(nil) }
    }

    // MARK: Custom keybindings

    private func loadKeybindings() {
        keybindings = [:]
        for (k, v) in Services.shared.config.keybindings { keybindings[AnserConfig.normalizeKey(k)] = v }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.keybindings.isEmpty, !(NSApp.keyWindow is PickerPanel) else { return event }
            let key = Self.keyString(event)
            guard let action = self.keybindings[key], let pane = self.currentPane else { return event }
            self.runBinding(action, pane: pane)
            return nil
        }
    }

    private func runBinding(_ action: String, pane: PaneView) {
        let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts[0]
        let arg = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "run": pane.run(arg)
        case "insert": pane.insertIntoEditor(pane.editor.string + arg)
        case "snippet":
            if let s = Services.shared.config.snippets.first(where: { $0.name == arg }) { pane.insertIntoEditor(s.command) }
        case "action":
            if let a = AnserAction(rawValue: arg) { perform(a, pane: pane) } else { NSSound.beep() }
        case "ghostty": pane.surfaceView.binding(arg)
        default: NSSound.beep()
        }
    }

    static func keyString(_ e: NSEvent) -> String {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("alt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        let special: [Int: String] = [
            kVK_Return: "enter", kVK_Tab: "tab", kVK_Space: "space", kVK_Escape: "escape", kVK_Delete: "backspace",
            kVK_ForwardDelete: "delete", kVK_UpArrow: "up", kVK_DownArrow: "down", kVK_LeftArrow: "left", kVK_RightArrow: "right",
            kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pageup", kVK_PageDown: "pagedown",
            kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6",
            kVK_F7: "f7", kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12",
        ]
        let key = special[Int(e.keyCode)] ?? (e.characters(byApplyingModifiers: []) ?? "").lowercased()
        parts.append(key)
        return parts.joined(separator: "+")
    }

    // MARK: Config file watching

    private func watchConfig() {
        let fd = open(AnserConfig.fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            // Editors often replace the file; re-arm the watcher.
            self?.configWatcher?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.reloadConfig(nil)
                self?.watchConfig()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        configWatcher = src
    }
}
