import AppKit
import GhosttyKit
import AnserCore

/// One window with its own tab bar. Each tab holds a tree of split panes
/// (nested NSSplitViews), a name you can change, and an optional color.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    final class Tab {
        let id = UUID()
        var root: NSView
        weak var focusedPane: PaneView?
        /// Set when you rename the tab; otherwise the title follows the shell.
        var customTitle: String?
        var color: String?
        /// Color from a matching profile (Settings → Profiles); a color you pick wins.
        var profileColor: String?
        /// What you type in one pane goes to every pane in this tab.
        var broadcasting = false
        /// A command finished / failed here while you were looking elsewhere.
        var unseenDone = false
        var unseenFailure = false
        /// A pane temporarily shown full size, and where it came from.
        var zoom: (pane: PaneView, parent: NSSplitView, index: Int, placeholder: NSView)?
        init(root: NSView) { self.root = root }
    }

    /// A saved split layout: panes (with their folders) and splits.
    indirect enum Layout: Codable {
        /// `session`: the kept shell's id (anser-session), so it comes back after a restart.
        case pane(cwd: String, session: String? = nil, draft: CommandDraft? = nil)
        case split(vertical: Bool, children: [Layout], sizes: [Double])
    }

    struct CommandDraft: Codable {
        var text: String
        var cursor: Int
    }

    struct SavedTab: Codable {
        var layout: Layout
        var title: String?
        var color: String?
    }

    private let container = NSView()
    let tabBar = TabBarView()
    let sidebar = SidebarView()
    private var sidebarWidth: NSLayoutConstraint!
    static let sidebarDefaultWidth: CGFloat = 230
    let notebookPanel = NotebookPanelView()
    private var notebookWidth: NSLayoutConstraint!
    var notebookPanelVisible: Bool { notebookWidth.constant > 0 }
    var sidebarVisible: Bool { sidebarWidth.constant > 0 }
    private let content = NSView()
    var picker: PickerPanel?
    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex = 0
    private var tabBarHeight: NSLayoutConstraint!
    /// The drop-down window from the global shortcut (not saved with the session).
    var isQuickTerminal = false
    var workspaceName: String?

    var selectedTab: Tab? { tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil }
    var focusedPane: PaneView? { selectedTab?.focusedPane ?? allPanes.first }

    convenience init(cwd: String?) {
        self.init(tabs: [SavedTab(layout: .pane(cwd: cwd ?? NSHomeDirectory()))], selected: 0, frame: nil)
    }

    init(tabs saved: [SavedTab], selected: Int, frame: NSRect?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 220)
        super.init(window: window)
        window.delegate = self

        container.wantsLayer = true
        window.contentView = container
        tabBar.controller = self
        sidebar.controller = self
        notebookPanel.controller = self
        for v in [tabBar, sidebar, content, notebookPanel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 34)
        let showSidebar = UserDefaults.standard.bool(forKey: "AnserSidebar") && ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: showSidebar ? Self.sidebarDefaultWidth : 0)
        sidebarWidth.isActive = true
        sidebar.isHidden = !showSidebar
        let showNotebook = UserDefaults.standard.bool(forKey: "AnserNotebookPanel") && ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil
        notebookWidth = notebookPanel.widthAnchor.constraint(equalToConstant: showNotebook ? NotebookPanelView.defaultWidth : 0)
        notebookWidth.isActive = true
        notebookPanel.isHidden = !showNotebook
        if showNotebook { notebookPanel.reload() }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: container.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tabBarHeight,
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sidebar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: notebookPanel.leadingAnchor),
            notebookPanel.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            notebookPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            notebookPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        for t in saved {
            let tab = Tab(root: build(t.layout))
            tab.customTitle = t.title
            tab.color = t.color
            tabs.append(tab)
            attach(tab.root)
            let layout = t.layout, root = tab.root
            DispatchQueue.main.async { [weak self] in self?.applySplitSizes(layout, root) }
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else if let key = NSApp.keyWindow, key.windowController is TerminalWindowController {
            // Offset from the current window instead of stacking exactly on it.
            window.setFrame(key.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: key.frame.minX, y: key.frame.maxY)))
        } else if !window.setFrameUsingName("AnserMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("")
        applyTheme()
        selectTab(min(max(selected, 0), tabs.count - 1), focus: false)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .anserThemeChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() { applyTheme() }

    private func applyTheme() {
        let t = GhosttyRuntime.shared.theme
        let opacity = CGFloat(Services.shared.config.appearance.backgroundOpacity ?? 1)
        window?.isOpaque = opacity >= 1
        window?.backgroundColor = opacity >= 1 ? t.background : t.background.withAlphaComponent(opacity)
        window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        tabBar.reload()
    }

    private func makePane(cwd: String?, sessionID: String? = nil) -> PaneView {
        let p = PaneView(cwd: cwd, sessionID: sessionID)
        p.windowController = self
        return p
    }

    private func build(_ node: Layout) -> NSView {
        switch node {
        case let .pane(cwd, session, draft):
            let path = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
            let pane = makePane(cwd: path, sessionID: session)
            if let draft, Services.shared.config.restoreDrafts, pane.session.cwd == cwd, !pane.session.isRemote {
                pane.editor.setCommand(draft.text)
                pane.editor.setSelectedRange(NSRange(location: max(0, min(draft.cursor, draft.text.utf16.count)), length: 0))
            }
            return pane
        case let .split(vertical, children, _):
            let split = makeSplit(vertical: vertical)
            for c in children { split.addArrangedSubview(build(c)) }
            return split
        }
    }

    private func makeSplit(vertical: Bool) -> NSSplitView {
        let split = NSSplitView()
        split.isVertical = vertical
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = true
        split.autoresizingMask = [.width, .height]
        return split
    }

    private func applySplitSizes(_ node: Layout, _ view: NSView) {
        guard case let .split(vertical, children, sizes) = node, let split = view as? NSSplitView else { return }
        split.layoutSubtreeIfNeeded()
        let total = vertical ? split.bounds.width : split.bounds.height
        var pos: CGFloat = 0
        for i in 0..<max(0, min(sizes.count, children.count) - 1) {
            pos += CGFloat(sizes[i]) * total
            split.setPosition(pos, ofDividerAt: i)
        }
        for (c, v) in zip(children, split.arrangedSubviews) { applySplitSizes(c, v) }
    }

    private func layout(of root: NSView, tab: Tab, includeSession: Bool) -> Layout {
        let view = tab.zoom.flatMap { root === $0.placeholder ? $0.pane : nil } ?? root
        if let pane = view as? PaneView {
            let session = pane.session
            let config = Services.shared.config
            var draft: CommandDraft?
            if includeSession, config.restoreSession, config.restoreDrafts, !session.historyPaused, !session.isRemote, pane.sshTarget == nil {
                let text = pane.editor.string
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !config.shouldIgnoreInHistory(text), AIHelp.redact(text) == text {
                    draft = CommandDraft(text: text, cursor: pane.editor.selectedRange().location)
                }
            }
            return .pane(cwd: session.cwd, session: includeSession && session.persistent ? session.id : nil, draft: draft)
        }
        if let split = view as? NSSplitView {
            let total = max(1, split.isVertical ? split.bounds.width : split.bounds.height)
            return .split(vertical: split.isVertical, children: split.arrangedSubviews.map { layout(of: $0, tab: tab, includeSession: includeSession) },
                          sizes: split.arrangedSubviews.map { Double((split.isVertical ? $0.frame.width : $0.frame.height) / total) })
        }
        return .pane(cwd: NSHomeDirectory())
    }

    /// The selected tab's split layout.
    func snapshot() -> Layout? { selectedTab.map { layout(of: $0.root, tab: $0, includeSession: true) } }

    /// Workspaces reuse the layout with fresh shells. Session restore keeps the live shell and eligible drafts.
    func snapshotTabs(includeSession: Bool = true) -> [SavedTab] {
        tabs.map { SavedTab(layout: layout(of: $0.root, tab: $0, includeSession: includeSession), title: $0.customTitle, color: $0.color) }
    }

    /// Puts a tab's root view into the content area.
    private func attach(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func replaceRoot(of tab: Tab, with view: NSView) {
        let hidden = tab.root.isHidden
        if tab.root.superview === content { tab.root.removeFromSuperview() }
        tab.root = view
        attach(view)
        view.isHidden = hidden
    }

    private func panes(in view: NSView) -> [PaneView] {
        if let p = view as? PaneView { return [p] }
        return view.subviews.flatMap(panes(in:))
    }

    /// Panes in the selected tab.
    var allPanes: [PaneView] { selectedTab.map { panes(in: $0.root) + ($0.zoom.map { [$0.pane] } ?? []) } ?? [] }
    /// Panes in every tab of this window.
    var allPanesEverywhere: [PaneView] { tabs.flatMap { panes(in: $0.root) + ($0.zoom.map { [$0.pane] } ?? []) } }

    // MARK: Sidebar

    func toggleSidebar() {
        let show = !sidebarVisible
        if show { sidebar.isHidden = false; sidebar.refresh(for: focusedPane) }
        // Set the final width directly (so it always takes effect), and let
        // the layout pass inside the animation group slide it in.
        sidebarWidth.constant = show ? Self.sidebarDefaultWidth : 0
        tabBar.updateSidebarButton()
        refreshSidebar()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.sidebarVisible { self.sidebar.isHidden = true }
        })
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil {
            UserDefaults.standard.set(show, forKey: "AnserSidebar")
        }
    }

    /// The Command Notebook panel on the right (⌥⌘N, or the book at the right of the tab bar).
    func toggleNotebookPanel() {
        let show = !notebookPanelVisible
        if show { notebookPanel.isHidden = false; notebookPanel.reload() }
        notebookWidth.constant = show ? NotebookPanelView.defaultWidth : 0
        tabBar.updateSidebarButton()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            window?.contentView?.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if !self.notebookPanelVisible { self.notebookPanel.isHidden = true }
        })
        if ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil {
            UserDefaults.standard.set(show, forKey: "AnserNotebookPanel")
        }
    }

    func refreshSidebar() {
        if sidebarVisible { sidebar.refresh(for: focusedPane) }
    }

    // MARK: Split chrome (headers, dimming, zoom)

    /// Headers and dimming only make sense when a tab is split.
    func refreshPaneChrome(_ tab: Tab) {
        let list = panes(in: tab.root) + (tab.zoom.map { [$0.pane] } ?? [])
        let split = list.count > 1
        for p in list {
            p.showsHeader = split
            p.dimmed = split && tab.zoom == nil && p !== tab.focusedPane
            p.zoomed = tab.zoom?.pane === p
            p.needsLayout = true
        }
    }

    /// Shows one pane at full size (⇧⌘↩); again to put it back in its split.
    func toggleZoom(_ pane: PaneView) {
        guard let tab = tab(for: pane) ?? tabs.first(where: { $0.zoom?.pane === pane }) else { return }
        if let z = tab.zoom {
            z.pane.removeFromSuperview()
            z.pane.translatesAutoresizingMaskIntoConstraints = true
            z.pane.autoresizingMask = [.width, .height]
            if let i = z.parent.arrangedSubviews.firstIndex(of: z.placeholder) {
                z.pane.frame = z.placeholder.frame
                z.parent.removeArrangedSubview(z.placeholder)
                z.placeholder.removeFromSuperview()
                z.parent.insertArrangedSubview(z.pane, at: i)
            }
            tab.zoom = nil
            tab.root.isHidden = false
        } else {
            guard let parent = pane.superview as? NSSplitView, let i = parent.arrangedSubviews.firstIndex(of: pane) else { NSSound.beep(); return }
            let placeholder = NSView(frame: pane.frame)
            parent.removeArrangedSubview(pane)
            pane.removeFromSuperview()
            parent.insertArrangedSubview(placeholder, at: i)
            tab.zoom = (pane, parent, i, placeholder)
            tab.root.isHidden = true
            attach(pane)
        }
        refreshPaneChrome(tab)
        pane.focus()
    }

    func panes(inTab i: Int) -> [PaneView] { tabs.indices.contains(i) ? panes(in: tabs[i].root) : [] }

    func tab(for pane: PaneView) -> Tab? { tabs.first { pane.isDescendant(of: $0.root) || $0.zoom?.pane === pane } }

    // MARK: Tabs

    func title(of tab: Tab) -> String {
        if let t = tab.customTitle, !t.isEmpty { return t }
        return (tab.focusedPane ?? panes(in: tab.root).first)?.displayTitle ?? "Terminal"
    }

    func addTab(cwd: String?) {
        let tab = Tab(root: makePane(cwd: cwd))
        attach(tab.root)
        let at = min(selectedIndex + 1, tabs.count)
        tabs.insert(tab, at: at)
        selectTab(at)
    }

    func selectTab(_ index: Int, focus: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        for (i, t) in tabs.enumerated() {
            let visible = i == index
            t.root.isHidden = !visible || t.zoom != nil
            t.zoom?.pane.isHidden = !visible
            panes(in: t.root).forEach { $0.surfaceView.setVisible(visible) }
            t.zoom?.pane.surfaceView.setVisible(visible)
        }
        let tab = tabs[index]
        tab.unseenDone = false
        tab.unseenFailure = false
        if tab.focusedPane == nil { tab.focusedPane = panes(in: tab.root).first }
        window?.title = title(of: tab)
        tabBar.reload()
        refreshSidebar()
        if focus { tab.focusedPane?.focus() }
    }

    func selectNextTab(_ forward: Bool) {
        guard tabs.count > 1 else { return }
        selectTab((selectedIndex + (forward ? 1 : -1) + tabs.count) % tabs.count)
    }

    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let selected = selectedTab
        let t = tabs.remove(at: from)
        tabs.insert(t, at: to)
        selectedIndex = tabs.firstIndex { $0 === selected } ?? to
        tabBar.reload()
    }

    /// Moves the selected tab one place left or right.
    func moveSelectedTab(by delta: Int) {
        let to = selectedIndex + delta
        guard tabs.indices.contains(to) else { NSSound.beep(); return }
        moveTab(from: selectedIndex, to: to)
    }

    /// Takes a tab (with its shells still running) out into a window of its own.
    func moveTabToNewWindow(_ index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        let tab = tabs.remove(at: index)
        tab.root.removeFromSuperview()
        let wc = TerminalWindowController(adopting: tab)
        AppDelegate.shared.adopt(wc)
        selectTab(min(index, tabs.count - 1), focus: false)
    }

    /// A window that takes over an existing tab from another window.
    convenience init(adopting tab: Tab) {
        self.init(tabs: [], selected: 0, frame: nil)
        tabs = [tab]
        attach(tab.root)
        panes(in: tab.root).forEach { $0.windowController = self }
        selectTab(0, focus: false)
    }

    func renameTab(_ index: Int, to name: String?) {
        guard tabs.indices.contains(index) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespaces)
        tabs[index].customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if index == selectedIndex { window?.title = title(of: tabs[index]) }
        tabBar.reload()
    }

    func beginRenamingSelectedTab() { tabBar.beginEditing(selectedIndex) }

    /// Tests: a tab built from a saved layout (as session restore does).
    func addTab(restoring layout: Layout) {
        let tab = Tab(root: build(layout))
        tabs.append(tab)
        attach(tab.root)
        selectTab(tabs.count - 1)
    }

    func setTabColor(_ index: Int, _ color: String?) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].color = color
        tabBar.reload()
    }

    /// Closes a whole tab, asking first if programs are running in it.
    func closeTabAsking(_ index: Int) {
        guard tabs.indices.contains(index), let window else { return }
        let busy = panes(in: tabs[index].root).filter(\.hasRunningProcess)
        guard !busy.isEmpty else { closeTab(index); return }
        let a = NSAlert()
        a.messageText = "Close this tab?"
        a.informativeText = busy.map(\.runningDescription).joined(separator: "\n") + "\n\nThis will be stopped."
        a.addButton(withTitle: "Close")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.closeTab(index) }
        }
    }

    func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        panes(in: tab.root).forEach { $0.teardown() }
        tab.root.removeFromSuperview()
        tabs.remove(at: index)
        guard !tabs.isEmpty else { window?.close(); return }
        selectTab(min(index, tabs.count - 1))
    }

    func closeOtherTabs(_ keep: Int) {
        guard tabs.indices.contains(keep) else { return }
        let keepTab = tabs[keep]
        for i in tabs.indices.reversed() where tabs[i] !== keepTab { closeTab(i) }
    }

    // MARK: Focus

    /// What a tab is doing, for its indicator in the tab bar.
    enum Activity { case idle, running, waiting, done, failed }

    func activity(of tab: Tab) -> Activity {
        let list = panes(in: tab.root)
        if list.contains(where: { $0.waitState != nil }) { return .waiting }
        if list.contains(where: { $0.session.running != nil }) { return .running }
        if tab.unseenFailure { return .failed }
        if tab.unseenDone { return .done }
        return .idle
    }

    /// A pane started or finished a command.
    func paneActivityChanged(_ pane: PaneView, finished: Bool, failed: Bool) {
        if finished, let tab = tab(for: pane), tab !== selectedTab || !(window?.isKeyWindow ?? false) {
            if failed { tab.unseenFailure = true } else { tab.unseenDone = true }
        }
        tabBar.reload()
        if finished, pane === focusedPane { refreshSidebar() }
    }

    func paneDidFocus(_ pane: PaneView) {
        guard let tab = tab(for: pane), tab.focusedPane !== pane else { return }
        tab.focusedPane = pane
        refreshPaneChrome(tab)
        paneTitleChanged(pane)
        refreshSidebar()
    }

    func focusPane(relativeTo pane: PaneView, forward: Bool) {
        let list = tab(for: pane).map { panes(in: $0.root) } ?? []
        guard list.count > 1, let i = list.firstIndex(where: { $0 === pane }) else { return }
        let next = list[(i + (forward ? 1 : -1) + list.count) % list.count]
        tab(for: next)?.focusedPane = next
        next.focus()
    }

    func paneTitleChanged(_ pane: PaneView) {
        guard let tab = tab(for: pane) else { return }
        pane.needsLayout = true
        if tab === selectedTab {
            window?.title = title(of: tab)
            window?.representedURL = URL(fileURLWithPath: pane.session.cwd)
        }
        tabBar.reload()
    }

    // MARK: Splits

    /// Splits `pane` in two. `before`: the new pane goes on the left (or above) instead of right (or below).
    func split(_ pane: PaneView, vertical: Bool, before: Bool = false) {
        guard let tab = tab(for: pane) else { return }
        if tab.zoom != nil { toggleZoom(tab.zoom!.pane) }
        let newPane = makePane(cwd: pane.session.cwd)
        let split = makeSplit(vertical: vertical)

        if let parent = pane.superview as? NSSplitView, let idx = parent.arrangedSubviews.firstIndex(of: pane) {
            let frame = pane.frame
            parent.removeArrangedSubview(pane)
            pane.removeFromSuperview()
            split.frame = frame
            parent.insertArrangedSubview(split, at: idx)
        } else {
            replaceRoot(of: tab, with: split)
        }
        split.addArrangedSubview(before ? newPane : pane)
        split.addArrangedSubview(before ? pane : newPane)
        split.layoutSubtreeIfNeeded()
        let total = vertical ? split.bounds.width : split.bounds.height
        split.setPosition(total / 2, ofDividerAt: 0)
        tab.focusedPane = newPane
        refreshPaneChrome(tab)
        DispatchQueue.main.async { newPane.focus() }
    }

    /// Closes a pane, asking first if a program is still running in it.
    func closeAsking(_ pane: PaneView) {
        guard pane.hasRunningProcess, let window else { close(pane); return }
        let a = NSAlert()
        a.messageText = "Close this pane?"
        a.informativeText = "\(pane.runningDescription) is still running and will be stopped."
        a.addButton(withTitle: "Close")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.close(pane) }
        }
    }

    func close(_ pane: PaneView) {
        guard let tab = tab(for: pane), let tabIndex = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab.zoom != nil { toggleZoom(tab.zoom!.pane) }
        let list = panes(in: tab.root)
        // The last pane in a tab closes the tab.
        guard list.count > 1 else { closeTab(tabIndex); return }
        let index = list.firstIndex { $0 === pane } ?? 0
        pane.teardown()
        if let parent = pane.superview as? NSSplitView {
            parent.removeArrangedSubview(pane)
            pane.removeFromSuperview()
            // A split with one child left collapses into that child.
            if parent.arrangedSubviews.count == 1, let only = parent.arrangedSubviews.first {
                parent.removeArrangedSubview(only)
                only.removeFromSuperview()
                if let grand = parent.superview as? NSSplitView, let gi = grand.arrangedSubviews.firstIndex(of: parent) {
                    only.frame = parent.frame
                    only.translatesAutoresizingMaskIntoConstraints = true
                    only.autoresizingMask = [.width, .height]
                    grand.removeArrangedSubview(parent)
                    parent.removeFromSuperview()
                    grand.insertArrangedSubview(only, at: gi)
                } else {
                    replaceRoot(of: tab, with: only)
                }
            }
        }
        let remaining = panes(in: tab.root)
        let next = remaining[min(max(index - 1, 0), remaining.count - 1)]
        tab.focusedPane = next
        refreshPaneChrome(tab)
        if tab === selectedTab { next.focus() }
        tabBar.reload()
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        focusedPane?.focus()
    }

    func windowWillEnterFullScreen(_ notification: Notification) { tabBar.inFullScreen = true }
    func windowWillExitFullScreen(_ notification: Notification) { tabBar.inFullScreen = false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let busy = allPanesEverywhere.filter(\.hasRunningProcess)
        guard !busy.isEmpty, !AppDelegate.shared.isTerminating else { return true }
        let a = NSAlert()
        a.messageText = busy.count == 1 ? "Close this window?" : "Close this window with \(busy.count) running programs?"
        a.informativeText = busy.map(\.runningDescription).joined(separator: "\n") + "\n\nThey will be stopped."
        a.addButton(withTitle: "Close")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: sender) { r in
            if r == .alertFirstButtonReturn {
                sender.delegate = nil
                (sender.windowController as? TerminalWindowController)?.forceClose()
            }
        }
        return false
    }

    func forceClose() {
        picker?.close()
        allPanesEverywhere.forEach { $0.teardown() }
        AppDelegate.shared.windowClosed(self)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        picker?.close()
        allPanesEverywhere.forEach { $0.teardown() }
        AppDelegate.shared.windowClosed(self)
    }
}


/// Local and remote branches for the switcher. A class, so a background
/// fetch can update the list the open picker reads.
@MainActor
final class BranchList {
    private(set) var locals: [Suggestion] = []
    private(set) var remotes: [Suggestion] = []
    private(set) var remoteNames: [String] = []
    var hasRemotes: Bool { !remoteNames.isEmpty }

    func load(cwd: String, env: ShellEnvironment) async {
        locals = await Generators.run("git_local_branches", cwd: cwd, env: env)
        remotes = await Generators.run("git_remote_branches", cwd: cwd, env: env)
        remoteNames = (await ScriptRunner.shared.run("git remote", cwd: cwd, env: env) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Remote names come first ("origin/feature"); drop bare "origin" (its HEAD).
        remotes = remotes.filter { r in !remoteNames.contains(r.name) && r.name.contains("/") }
    }

    /// `git fetch` from every remote. Never asks for a password (it fails instead).
    /// Returns true when it failed or timed out.
    func fetch(cwd: String, env: ShellEnvironment) async -> Bool {
        let out = await ScriptRunner.shared.run(
            "GIT_SSH_COMMAND=\"${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=8}\" git fetch --all --prune --quiet 2>&1; echo \"exit=$?\"",
            cwd: cwd, env: env, timeout: 25)
        Generators.forgetCache(cwd: cwd)
        return !(out ?? "").contains("exit=0")
    }

    /// "origin/feature/x" → "feature/x".
    nonisolated static func shortName(_ remoteBranch: String) -> String {
        String(remoteBranch.split(separator: "/", maxSplits: 1).last ?? Substring(remoteBranch))
    }
}
