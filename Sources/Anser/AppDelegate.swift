import AppKit
import Carbon.HIToolbox
import GhosttyKit
import AnserCore
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate, UNUserNotificationCenterDelegate {
    static var shared: AppDelegate!

    private var windows: [TerminalWindowController] = []
    private var keyMonitor: Any?
    private var keybindings: [String: String] = [:]
    private(set) var isActive = true
    /// Files and links opened before the first window existed.
    var pendingOpenURLs: [URL] = []
    private(set) var didFinishLaunching = false
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
        UNUserNotificationCenter.current().delegate = self
        buildMenu()
        loadKeybindings()
        installKeyMonitor()
        watchConfig()
        QuickTerminal.shared.configure(Services.shared.config.quickTerminalHotkey)
        Updater.shared.start()
        // Count menu use (only when usage counting is on; stays on this Mac).
        NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { n in
            guard let item = n.userInfo?["MenuItem"] as? NSMenuItem, item.representedObject == nil else { return }
            Services.shared.record("menu." + item.title.replacingOccurrences(of: "…", with: ""))
        }
        let selfTest = ProcessInfo.processInfo.environment["ANSER_SELFTEST"] != nil
        let restored = !selfTest && Services.shared.config.restoreSession && restoreSession()
        if !restored { newWindow(cwd: nil) }
        // Shells left from before that no window came back to are ended.
        if SessionHost.shared.helperPath != nil {
            SessionHost.shared.keepOnly(Set(allPanes.filter(\.session.persistent).map(\.session.id)))
        }
        startAutosave()
        if !selfTest, !UserDefaults.standard.bool(forKey: "AnserWelcomeShown") { currentPane?.showWelcome() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerCrashReport() }
        NSApp.activate(ignoringOtherApps: true)
        if let err = Services.shared.configError { showConfigError(err) }
        didFinishLaunching = true
        openPendingURLs()
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

    /// Set by "Quit and End All Shells".
    private(set) var endShellsOnQuit = false
    /// Shells survive this quit (anser-session keeps them for the next launch).
    var keepingShellsOnQuit: Bool { SessionHost.shared.keepOnQuit && !endShellsOnQuit && !Services.isSelfTest }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing stops when shells are kept, so there's nothing to warn about.
        if keepingShellsOnQuit { isTerminating = true; return .terminateNow }
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
        let panes = allPanes.filter(\.session.persistent)
        if keepingShellsOnQuit {
            panes.forEach { SessionHost.shared.save($0.session) }
        } else {
            for p in panes { SessionHost.shared.request(["cmd": "kill", "id": p.session.id], timeout: 0.5) }
        }
    }

    @objc func quitEndingShells(_ s: Any?) {
        endShellsOnQuit = true
        NSApp.terminate(nil)
        endShellsOnQuit = false   // still here: the quit was cancelled
    }

    /// Saves windows and kept shells every so often, so even a crash or forced
    /// quit brings your shells back.
    private func startAutosave() {
        guard ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil else { return }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, SessionHost.shared.keepOnQuit, !self.isTerminating else { return }
            self.saveSession()
            self.allPanes.filter(\.session.persistent).forEach { SessionHost.shared.save($0.session) }
        }
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
        for wc in windows where !wc.isQuickTerminal {
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

    // MARK: Dock menu

    /// Right-click (or click and hold) the Dock icon: New Window, New Tab.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let win = NSMenuItem(title: "New Window", action: #selector(dockNewWindow(_:)), keyEquivalent: "")
        let tab = NSMenuItem(title: "New Tab", action: #selector(dockNewTab(_:)), keyEquivalent: "")
        for i in [win, tab] { i.target = self; m.addItem(i) }
        if QuickTerminal.shared.hotKey != nil {
            let q = NSMenuItem(title: QuickTerminal.shared.isShown ? "Hide Quick Terminal" : "Show Quick Terminal", action: #selector(dockQuickTerminal(_:)), keyEquivalent: "")
            q.target = self
            m.addItem(q)
        }
        return m
    }

    @objc func dockNewWindow(_ s: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        newWindow(cwd: nil)
    }

    /// A tab in the frontmost regular window (a new window if there is none).
    @objc func dockNewTab(_ s: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let front = NSApp.orderedWindows.compactMap { $0.windowController as? TerminalWindowController }
            .first { !$0.isQuickTerminal && ($0.window?.isVisible ?? false) }
        guard let wc = front else { newWindow(cwd: nil); return }
        wc.window?.makeKeyAndOrderFront(nil)
        wc.addTab(cwd: wc.focusedPane?.session.cwd)
    }

    @objc func dockQuickTerminal(_ s: Any?) { QuickTerminal.shared.toggle() }

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

    /// Opens a tab and runs a command in it (e.g. installing or signing in to a tool).
    func runInNewTab(_ command: String) {
        newTab(from: currentPane)
        guard let wc = currentController else { return }
        let start = Date()
        func attempt() {
            if let p = wc.focusedPane, p.session.atPrompt { p.run(command); wc.window?.makeKeyAndOrderFront(nil); return }
            if Date().timeIntervalSince(start) < 8 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { attempt() } }
        }
        attempt()
    }

    func windowClosed(_ wc: TerminalWindowController) {
        windows.removeAll { $0 === wc }
        QuickTerminal.shared.windowClosed(wc)
    }

    /// Registers a window without showing it (the quick terminal shows itself).
    func adoptQuietly(_ wc: TerminalWindowController) {
        windows.append(wc)
    }

    /// Every pane in every window.
    var allPanes: [PaneView] { windows.flatMap(\.allPanesEverywhere) }

    // MARK: Notifications

    /// Clicking "Command finished" brings you to that tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        DispatchQueue.main.async { [weak self] in
            if let id { self?.reveal(sessionID: id) }
            done()
        }
    }

    /// Shown even while Anser is in front (the command's tab may be hidden).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// Brings the window and tab running a session to the front.
    @discardableResult
    func reveal(sessionID: String) -> Bool {
        guard let pane = allPanes.first(where: { $0.session.id == sessionID }), let wc = pane.windowController,
              let tab = wc.tab(for: pane), let i = wc.tabs.firstIndex(where: { $0 === tab }) else { return false }
        NSApp.activate(ignoringOtherApps: true)
        if wc.isQuickTerminal { QuickTerminal.shared.show() }
        wc.selectTab(i)
        wc.window?.makeKeyAndOrderFront(nil)
        pane.focus()
        return true
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
        /// A menu item that runs an AnserAction (so menus, palette and keybindings share one path).
        func actionItem(_ a: AnserAction, _ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = item(title, #selector(performMenuAction(_:)), key, mods, for: a)
            i.representedObject = a.rawValue
            return i
        }

        // App
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(item("About Anser", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(actionItem(.checkForUpdates, "Check for Updates…", ""))
        app.addItem(.separator())
        app.addItem(item("Make Anser the Default Terminal…", #selector(toggleDefaultTerminal(_:))))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openSettings(_:)), ",", for: .openSettings))
        app.addItem(item("Open Config File", #selector(openConfig(_:)), ",", [.command, .option], for: .openConfig))
        app.addItem(item("Reload Config", #selector(reloadConfig(_:)), ",", [.command, .shift], for: .reloadConfig))
        app.addItem(actionItem(.importSettings, "Import from iTerm2 or Warp…", ""))
        app.addItem(.separator())
        app.addItem(item("Hide Anser", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        app.addItem(.separator())
        app.addItem(item("Quit Anser", #selector(NSApplication.terminate(_:)), "q"))
        let endAll = item("Quit and End All Shells", #selector(quitEndingShells(_:)), "q", [.command, .option])
        endAll.isAlternate = true
        app.addItem(endAll)
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
        shell.addItem(actionItem(.splitLeft, "Split Left", ""))
        shell.addItem(actionItem(.splitUp, "Split Up", ""))
        shell.addItem(.separator())
        shell.addItem(item("Re-run Last Command", #selector(rerunLast(_:)), "r", [.command, .shift], for: .rerunLastCommand))
        shell.addItem(actionItem(.broadcastInput, "Type in All Panes of This Tab", "b", [.command, .option, .shift]))
        shell.addItem(actionItem(.shareTab, "Share This Tab (Read-Only)…", ""))
        shell.addItem(.separator())
        shell.addItem(item("Export Tab…", #selector(exportMarkdown(_:)), "s", [.command, .shift], for: .exportMarkdown))
        shell.addItem(actionItem(.exportLastOutput, "Export Last Command’s Output…", "s", [.command, .option, .shift]))
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
        edit.addItem(actionItem(.searchAllTabs, "Find in All Tabs…", "f", [.command, .shift]))
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
        view.addItem(item("Clear", #selector(clearScreen(_:)), "k", for: .clearScreen))
        view.addItem(actionItem(.deepClean, "Deep Clean…", "k", [.command, .shift]))
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
        go.addItem(actionItem(.searchOutput, "Search Command Output…", "f", [.command, .option, .shift]))
        go.addItem(item("Command Palette…", #selector(commandPalette(_:)), "p", [.command, .shift], for: .commandPalette))
        go.addItem(item("Commands in This Tab…", #selector(blockNavigator(_:)), "b", for: .blockNavigator))
        go.addItem(item("Jump to Folder…", #selector(jumpToFolder(_:)), "j", for: .jumpToFolder))
        go.addItem(.separator())
        go.addItem(.separator())
        go.addItem(item("Next Pane", #selector(nextPane(_:)), "]", for: .focusNextPane))
        go.addItem(item("Previous Pane", #selector(prevPane(_:)), "[", for: .focusPreviousPane))
        go.addItem(item("Zoom Pane", #selector(zoomPane(_:)), "\r", [.command, .shift], for: .zoomPane))
        goItem.submenu = go
        main.addItem(goItem)

        // Git
        let gitItem = NSMenuItem()
        let git = NSMenu(title: "Git")
        git.addItem(item("Switch Branch…", #selector(switchBranch(_:)), "b", [.command, .shift], for: .switchBranch))
        git.addItem(item("Changed Files…", #selector(changedFiles(_:)), "g", [.command, .shift], for: .changedFiles))
        git.addItem(actionItem(.gitHistory, "Commit History…", "l", [.command, .shift]))
        git.addItem(actionItem(.gitStashes, "Stashes…", ""))
        git.addItem(actionItem(.gitBlame, "Blame File…", "l", [.command, .option, .shift]))
        git.addItem(actionItem(.resolveConflicts, "Resolve Conflicts…", ""))
        git.addItem(actionItem(.openPullRequest, "Open Pull Request", ""))
        git.addItem(.separator())
        git.addItem(actionItem(.gitFetch, "Fetch", ""))
        git.addItem(actionItem(.gitPull, "Pull", ""))
        git.addItem(actionItem(.gitPush, "Push", ""))
        gitItem.submenu = git
        main.addItem(gitItem)

        // Tools
        let toolsItem = NSMenuItem()
        let tools = NSMenu(title: "Tools")
        tools.addItem(actionItem(.notebook, "Command Notebook", "n", [.command, .option]))
        tools.addItem(actionItem(.editNotebook, "Edit Notebook…", ""))
        tools.addItem(actionItem(.saveToNotebook, "Save Command to Notebook", "s", [.command, .option]))
        tools.addItem(.separator())
        tools.addItem(item("Workflows…", #selector(runWorkflow(_:)), "r", [.command, .option], for: .runWorkflow))
        tools.addItem(item("Save Commands as Workflow…", #selector(saveWorkflow(_:)), "", for: .saveWorkflow))
        tools.addItem(actionItem(.openWorkflowsFolder, "Open Workflows Folder", ""))
        tools.addItem(.separator())
        tools.addItem(item("Ask AI for a Command…", #selector(askClaude(_:)), "i", for: .askClaude))
        tools.addItem(item("Explain Last Error with AI", #selector(explainError(_:)), "i", [.command, .option], for: .explainError))
        toolsItem.submenu = tools
        main.addItem(toolsItem)

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
        win.addItem(actionItem(.quickTerminal, "Quick Terminal", ""))
        win.addItem(item("Show Last Tab", #selector(selectLastTab(_:)), "9"))
        // The front window's tabs are listed here, rebuilt each time (see menuNeedsUpdate).
        win.addItem(.separator())
        win.delegate = self
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
        help.addItem(actionItem(.showUsage, "Your Feature Usage…", ""))
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
        if menuItem.action == #selector(askClaude(_:)) {
            menuItem.title = Services.shared.aiEnabled ? "Ask \(Services.shared.aiName) for a Command…" : "Ask AI for a Command…"
        }
        if menuItem.action == #selector(explainError(_:)) {
            menuItem.title = Services.shared.aiEnabled ? "Explain Last Error with \(Services.shared.aiName)" : "Explain Last Error with AI"
        }
        if menuItem.action == #selector(toggleSidebar(_:)) {
            menuItem.title = (currentController?.sidebarVisible ?? false) ? "Hide Sidebar" : "Show Sidebar"
        }
        if menuItem.action == #selector(pauseHistory(_:)) {
            menuItem.state = (currentPane?.session.historyPaused ?? false) ? .on : .off
        }
        if menuItem.action == #selector(quitEndingShells(_:)) { return SessionHost.shared.keepOnQuit }
        if menuItem.action == #selector(toggleDefaultTerminal(_:)) {
            let isDefault = isDefaultTerminal
            menuItem.state = isDefault ? .on : .off
            menuItem.title = isDefault ? "Anser Is the Default Terminal" : "Make Anser the Default Terminal…"
        }
        switch (menuItem.representedObject as? String).flatMap(AnserAction.init(rawValue:)) {
        case .quickTerminal?:
            let key = QuickTerminal.shared.hotKey.map { "  (\($0.display))" } ?? ""
            menuItem.title = (QuickTerminal.shared.isShown ? "Hide Quick Terminal" : "Show Quick Terminal") + key
        case .broadcastInput?:
            menuItem.state = currentPane.map { currentController?.isBroadcasting($0) ?? false } == true ? .on : .off
        case .shareTab?:
            let sharing = currentPane.flatMap { TabShare.share(for: $0) } != nil
            menuItem.title = sharing ? "Sharing This Tab (Read-Only)…" : "Share This Tab (Read-Only)…"
            menuItem.state = sharing ? .on : .off
        default: break
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
    @objc func performMenuAction(_ s: NSMenuItem) {
        guard let raw = s.representedObject as? String, let a = AnserAction(rawValue: raw) else { return }
        if a == .editNotebook { MainActor.assumeIsolated { NotebookWindow.shared.show() }; return }
        guard let p = currentPane else { NSSound.beep(); return }
        perform(a, pane: p)
    }
    @objc func switchBranch(_ s: Any?) { if let p = currentPane { currentController?.showBranchSwitcher(for: p) } }
    @objc func changedFiles(_ s: Any?) { if let p = currentPane { currentController?.showChanges(for: p) } }
    @objc func showShortcuts(_ s: Any?) { ShortcutsPanel.toggle(over: currentController?.window) }
    @objc func showWelcomeTips(_ s: Any?) { currentPane?.showWelcome() }
    @objc func reportProblem(_ s: Any?) { ReportProblemWindowController.shared.show() }
    @objc func askClaude(_ s: Any?) { currentPane?.askClaude() }
    @objc func explainError(_ s: Any?) { currentPane?.explainLastError() }
    @objc func runWorkflow(_ s: Any?) { if let p = currentPane { currentController?.showWorkflows(for: p) } }
    @objc func saveWorkflow(_ s: Any?) { if let p = currentPane { currentController?.showSaveWorkflow(for: p) } }
    @objc func exportMarkdown(_ s: Any?) { if let p = currentPane { currentController?.exportOutput(for: p, onlyLast: false) } }
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
        guard let c = currentController, s.tag >= Self.tabItemTag else { return }
        c.selectTab(min(s.tag - Self.tabItemTag, c.tabs.count - 1))
    }
    /// ⌘9 always means the last tab, like browsers.
    @objc func selectLastTab(_ s: Any?) {
        guard let c = currentController, !c.tabs.isEmpty else { return }
        c.selectTab(c.tabs.count - 1)
    }

    static let tabItemTag = 1000

    /// Lists the front window's tabs in the Window menu: real names, a check on the
    /// current one, ⌘1–⌘8 on the first eight. AppKit also calls this before matching
    /// key equivalents, so the shortcuts work without opening the menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === NSApp.windowsMenu else { return }
        for it in menu.items where it.tag >= Self.tabItemTag { menu.removeItem(it) }
        guard let c = currentController,
              let anchor = menu.items.firstIndex(where: { $0.action == #selector(selectLastTab(_:)) }) else { return }
        var at = anchor + 2   // after "Show Last Tab" and its separator
        for (i, tab) in c.tabs.enumerated() {
            let it = NSMenuItem(title: c.title(of: tab), action: #selector(selectTabN(_:)), keyEquivalent: i < 8 ? "\(i + 1)" : "")
            it.keyEquivalentModifierMask = .command
            it.tag = Self.tabItemTag + i
            it.target = self
            it.state = i == c.selectedIndex ? .on : .off
            menu.insertItem(it, at: at)
            at += 1
        }
        let sep = NSMenuItem.separator()
        sep.tag = Self.tabItemTag + 999
        menu.insertItem(sep, at: at)
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
        QuickTerminal.shared.configure(Services.shared.config.quickTerminalHotkey)
        allPanes.forEach { $0.updateProfile() }
        loadKeybindings()
        GhosttyRuntime.shared.reloadConfig()
        if let err = Services.shared.configError { showConfigError(err) }
    }

    func perform(_ a: AnserAction, pane: PaneView) {
        Services.shared.record("action." + a.rawValue)
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
        case .splitLeft: pane.windowController?.split(pane, vertical: true, before: true)
        case .splitUp: pane.windowController?.split(pane, vertical: false, before: true)
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
        case .exportMarkdown: currentController?.exportOutput(for: pane, onlyLast: false)
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
        case .notebook: currentController?.toggleNotebookPanel()
        case .editNotebook: MainActor.assumeIsolated { NotebookWindow.shared.show() }
        case .saveToNotebook: pane.saveToNotebook()
        case .exportLastOutput: currentController?.exportOutput(for: pane, onlyLast: true)
        case .openWorkflowsFolder: TerminalWindowController.openWorkflowsFolder()
        case .gitHistory: currentController?.showGitHistory(for: pane)
        case .gitStashes: currentController?.showStashes(for: pane)
        case .gitFetch: currentController?.runGit(.fetch, in: pane)
        case .gitPull: currentController?.runGit(.pull, in: pane)
        case .gitPush: currentController?.runGit(.push, in: pane); PaneView.forgetPullRequests()
        case .quickTerminal: QuickTerminal.shared.toggle()
        case .broadcastInput: pane.windowController?.toggleBroadcast(for: pane)
        case .searchOutput: pane.windowController?.showHistorySearch(for: pane, scope: .output)
        case .resolveConflicts: pane.windowController?.showConflicts(for: pane)
        case .openPullRequest: pane.openPullRequest()
        case .importSettings: importSettings()
        case .checkForUpdates: Updater.shared.checkForUpdates(nil)
        case .showUsage: showUsage()
        case .gitBlame: pane.windowController?.showBlameFilePicker(for: pane)
        case .searchAllTabs: pane.windowController?.showSearchAllTabs(for: pane)
        case .shareTab: pane.shareTab()
        case .deepClean: pane.confirmDeepClean()
        }
    }

    // MARK: Feedback

    func flash(_ pane: PaneView, _ text: String) {
        // A new message replaces the one still showing.
        let flashID = NSUserInterfaceItemIdentifier("anser-flash")
        pane.subviews.filter { $0.identifier == flashID }.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: text)
        label.identifier = flashID
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
            // A Command Notebook entry by title (or an old config.json snippet).
            if let s = Services.shared.config.snippets.first(where: { $0.name == arg }) { pane.insertIntoEditor(s.command) }
            else if let e = ((try? Notebook.load(from: NotebookWindow.fileURL)) ?? Notebook()).entry(titled: arg) { pane.insertIntoEditor(e.command) }
            else { NSSound.beep() }
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
