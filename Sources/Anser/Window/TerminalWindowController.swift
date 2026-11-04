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
        /// A command finished / failed here while you were looking elsewhere.
        var unseenDone = false
        var unseenFailure = false
        /// A pane temporarily shown full size, and where it came from.
        var zoom: (pane: PaneView, parent: NSSplitView, index: Int, placeholder: NSView)?
        init(root: NSView) { self.root = root }
    }

    /// A saved split layout: panes (with their folders) and splits.
    indirect enum Layout: Codable {
        case pane(cwd: String)
        case split(vertical: Bool, children: [Layout], sizes: [Double])
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
    var sidebarVisible: Bool { sidebarWidth.constant > 0 }
    private let content = NSView()
    private var picker: PickerPanel?
    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex = 0
    private var tabBarHeight: NSLayoutConstraint!

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
        for v in [tabBar, sidebar, content] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        tabBarHeight = tabBar.heightAnchor.constraint(equalToConstant: 34)
        let showSidebar = UserDefaults.standard.bool(forKey: "AnserSidebar") && ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: showSidebar ? Self.sidebarDefaultWidth : 0)
        sidebarWidth.isActive = true
        sidebar.isHidden = !showSidebar
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
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
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

    private func makePane(cwd: String?) -> PaneView {
        let p = PaneView(cwd: cwd)
        p.windowController = self
        return p
    }

    private func build(_ node: Layout) -> NSView {
        switch node {
        case let .pane(cwd):
            let path = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
            return makePane(cwd: path)
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

    private func layout(of root: NSView) -> Layout {
        if let p = root as? PaneView { return .pane(cwd: p.session.cwd) }
        if let s = root as? NSSplitView {
            let total = max(1, s.isVertical ? s.bounds.width : s.bounds.height)
            return .split(vertical: s.isVertical, children: s.arrangedSubviews.map(layout(of:)),
                          sizes: s.arrangedSubviews.map { Double((s.isVertical ? $0.frame.width : $0.frame.height) / total) })
        }
        return .pane(cwd: NSHomeDirectory())
    }

    /// The selected tab's split layout.
    func snapshot() -> Layout? { selectedTab.map { layout(of: $0.root) } }

    /// Every tab, for saving the session.
    func snapshotTabs() -> [SavedTab] {
        tabs.map { SavedTab(layout: layout(of: $0.root), title: $0.customTitle, color: $0.color) }
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
    enum Activity { case idle, running, done, failed }

    func activity(of tab: Tab) -> Activity {
        if panes(in: tab.root).contains(where: { $0.session.running != nil }) { return .running }
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

    func split(_ pane: PaneView, vertical: Bool) {
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
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)
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

    // MARK: Pickers

    func showHistorySearch(for pane: PaneView) {
        let history = Services.shared.history
        let sessionBlocks = pane.session.blocks
        presentPicker(PickerPanel.Config(
            title: "History",
            placeholder: "Search every command you've run…",
            scopes: HistoryScope.allCases.map(\.title),
            hint: "⏎ edit   ⌘⏎ run   ⌘C copy   ⌥⏎ copy output   ⌘⌫ forget   ⇥ scope",
            provider: { query, scope in
                let scopeValue = HistoryScope(rawValue: scope) ?? .all
                if scopeValue == .session {
                    // This tab: every run in order, with exit status and timing.
                    let blocks = Array(sessionBlocks.enumerated().reversed())
                    return blocks.compactMap { idx, b -> PickerItem? in
                        guard let m = Fuzzy.match(query, b.command) else { return nil }
                        let ok = (b.exitCode ?? 0) == 0
                        let outputIndex = sessionBlocks.count - 1 - idx
                        return PickerItem(
                            title: b.command,
                            subtitle: "\(Self.relative(b.started)) · \(Self.shortPath(b.cwd))\(b.duration.map { " · " + Services.formatDuration($0) } ?? "")",
                            accessory: ok ? "✓" : "✗ \(b.exitCode ?? 0)",
                            accessoryColor: ok ? .systemGreen : .systemRed,
                            positions: m.positions,
                            payload: ["command": b.command, "output": outputIndex])
                    }
                }
                return history.search(query, scope: scopeValue, cwd: pane.session.cwd, session: pane.session.id).map { c, m in
                    let failed = (c.lastExit ?? 0) != 0
                    return PickerItem(
                        title: c.command,
                        subtitle: "\(c.count)× · \(Self.relative(c.lastUsed))\(c.lastCwd.map { " · " + Self.shortPath($0) } ?? "")",
                        accessory: c.lastExit == nil ? nil : (failed ? "✗" : "✓"),
                        accessoryColor: failed ? .systemRed : .systemGreen,
                        positions: m.positions,
                        payload: ["command": c.command])
                }
            },
            onAccept: { [weak pane] item, mods in
                guard let pane, let payload = item.payload as? [String: Any], let cmd = payload["command"] as? String else { return }
                if mods.contains(.option), let idx = payload["output"] as? Int {
                    if let out = pane.output(ofBlock: pane.session.blocks.count - 1 - idx) { Self.copy(out) } else { NSSound.beep() }
                    return
                }
                if mods.contains(.command) { pane.insertIntoEditor(cmd, run: true) } else { pane.insertIntoEditor(cmd) }
            },
            onCopy: { item in (item.payload as? [String: Any])?["command"] as? String },
            onDelete: { item in
                if let cmd = (item.payload as? [String: Any])?["command"] as? String { history.delete(command: cmd) }
            },
            preview: { [weak pane] item in
                guard let payload = item.payload as? [String: Any], let cmd = payload["command"] as? String else { return nil }
                if let idx = payload["output"] as? Int, let pane, let out = pane.output(ofBlock: pane.session.blocks.count - 1 - idx) {
                    return PickerPanel.previewText("$ " + cmd + "\n\n" + out)
                }
                let c = history.search(cmd, scope: .all, limit: 50).first { $0.0.command == cmd }?.0
                var lines = ["$ " + cmd, ""]
                if let c {
                    lines.append("Run \(c.count) time\(c.count == 1 ? "" : "s"), last \(Self.relative(c.lastUsed))")
                    if let e = c.lastExit { lines.append(e == 0 ? "Last run succeeded" : "Last run failed with exit \(e)") }
                    if !c.cwds.isEmpty { lines += ["", "Folders:"] + c.cwds.sorted().prefix(12).map { "  " + Self.shortPath($0) } }
                }
                return PickerPanel.previewText(lines.joined(separator: "\n"))
            }), pane: pane)
    }

    /// Every command run in this tab, newest first: jump to it, copy its output, or re-run it.
    func showBlocks(for pane: PaneView) {
        let blocks = pane.session.blocks
        presentPicker(PickerPanel.Config(
            title: "Commands in this tab",
            placeholder: "Filter commands…",
            scopes: ["All", "Failed", "Slow (>5s)"],
            hint: "⏎ jump to it   ⌘C copy output   ⌥⏎ copy command   ⌘⏎ run again",
            provider: { query, scope in
                blocks.enumerated().reversed().compactMap { idx, b -> PickerItem? in
                    if scope == 1, (b.exitCode ?? 0) == 0 { return nil }
                    if scope == 2, (b.duration ?? 0) < 5 { return nil }
                    guard let m = Fuzzy.match(query, b.command) else { return nil }
                    let ok = (b.exitCode ?? 0) == 0
                    return PickerItem(
                        title: b.command,
                        subtitle: "\(Self.relative(b.started)) · \(Self.shortPath(b.cwd))\(b.duration.map { " · " + Services.formatDuration($0) } ?? "")",
                        accessory: ok ? "✓" : "✗ \(b.exitCode ?? 0)",
                        accessoryColor: ok ? .systemGreen : .systemRed,
                        positions: m.positions,
                        payload: (b.command, blocks.count - 1 - idx))
                }
            },
            onAccept: { [weak pane] item, mods in
                guard let pane, let (cmd, index) = item.payload as? (String, Int) else { return }
                if mods.contains(.command) { pane.insertIntoEditor(cmd, run: true); return }
                if mods.contains(.option) { Self.copy(cmd); return }
                pane.surfaceView.binding("scroll_to_bottom")
                pane.surfaceView.binding("jump_to_prompt:-\(index + 1)")
            },
            onCopy: { [weak pane] item in
                guard let (_, index) = item.payload as? (String, Int) else { return nil }
                guard let pane else { return nil }
                return pane.output(ofBlock: pane.session.blocks.count - 1 - index)
            },
            onDelete: nil,
            preview: { [weak pane] item in
                guard let (cmd, index) = item.payload as? (String, Int) else { return nil }
                let out = pane.flatMap { $0.output(ofBlock: $0.session.blocks.count - 1 - index) } ?? "(output not available)"
                return PickerPanel.previewText("$ " + cmd + "\n\n" + out)
            }), pane: pane)
    }

    /// Folders found by the disk scan, kept for a minute so ⌘J reopens instantly.
    private static var folderScan: (date: Date, root: String, paths: [String])?
    static func resetFolderScanCache() { folderScan = nil }

    /// Jump to a folder: ones you've used, `cd` targets from your shell
    /// history, and a quick scan of this folder and your home folder.
    func showFolderJumper(for pane: PaneView) {
        guard !pane.session.isRemote else { NSSound.beep(); return }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let current = pane.session.cwd
        let history = Services.shared.history

        final class Box: @unchecked Sendable { var candidates: [FolderIndex.Candidate] = []; var scanning = true }
        let box = Box()
        var seen = Set<String>([current])
        func add(_ path: String, _ boost: Double, _ note: String?) {
            guard seen.insert(path).inserted else { return }
            box.candidates.append(.init(path: path, boost: boost, note: note))
        }
        // 1. Folders you've used in Anser (strongest signal).
        for (i, d) in history.recentDirectories(limit: 200).enumerated() where fm.fileExists(atPath: d.path) {
            add(d.path, max(1, 6 - Double(i) * 0.05), "\(d.count) command\(d.count == 1 ? "" : "s") · \(Self.relative(d.last))")
        }
        // 2. Absolute folders from cd/pushd in your shell history.
        let cdCommands = history.recentCommands(withPrefix: "cd ", limit: 3000) + history.recentCommands(withPrefix: "pushd ", limit: 500)
        for p in FolderIndex.cdTargets(from: cdCommands, home: home) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { add(p, 1.5, "from your shell history") }
        }
        add(home, 1, "home")
        // 3. Recent scan, if fresh.
        if let cached = Self.folderScan, Date().timeIntervalSince(cached.date) < 60, cached.root == current {
            cached.paths.forEach { add($0, 0, nil) }
            box.scanning = false
        }

        let picker = presentPickerReturning(PickerPanel.Config(
            title: "Jump to folder",
            placeholder: "Type part of a folder name, or a path like ~/dev…",
            scopes: [],
            hint: "⏎ cd there   ⌘⏎ new tab there   ⌥⏎ open in Finder   ⌘C copy path",
            provider: { query, _ in
                var items: [PickerItem] = []
                // A typed path that exists goes first.
                var typed = query.trimmingCharacters(in: .whitespaces)
                if typed.hasPrefix("~") { typed = home + typed.dropFirst() }
                var isDir: ObjCBool = false
                if typed.hasPrefix("/"), fm.fileExists(atPath: typed, isDirectory: &isDir), isDir.boolValue {
                    items.append(PickerItem(title: Self.shortPath(typed), subtitle: "typed path", accessory: "go", accessoryColor: .systemGreen,
                                            positions: [], payload: (typed as NSString).standardizingPath))
                }
                for (c, m, shown) in FolderIndex.rank(query, box.candidates, home: home) {
                    let inHere = c.path.hasPrefix(current + "/")
                    let sub = c.note ?? (inHere ? "inside " + (current as NSString).lastPathComponent : nil)
                    items.append(PickerItem(title: shown, subtitle: sub, accessory: nil, accessoryColor: nil, positions: m.positions, payload: c.path))
                }
                if items.isEmpty && box.scanning {
                    items.append(PickerItem(title: "Searching folders…", subtitle: nil, accessory: nil, accessoryColor: nil, positions: [], payload: ""))
                }
                return items
            },
            onAccept: { [weak self, weak pane] item, mods in
                guard let pane, let path = item.payload as? String, !path.isEmpty else { return }
                if mods.contains(.option) { NSWorkspace.shared.open(URL(fileURLWithPath: path)); return }
                if mods.contains(.command) || !pane.session.atPrompt { self?.addTab(cwd: path); return }
                pane.run("cd " + ShellLexer.escape(path))
            },
            onCopy: { ($0.payload as? String).flatMap { $0.isEmpty ? nil : $0 } },
            onDelete: nil,
            preview: { item in
                guard let path = item.payload as? String, !path.isEmpty else { return nil }
                let entries = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                var lines = [Self.shortPath(path), ""]
                for e in entries.prefix(80) {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: path + "/" + e, isDirectory: &isDir)
                    lines.append((isDir.boolValue ? "▸ " : "  ") + e + (isDir.boolValue ? "/" : ""))
                }
                if entries.count > 80 { lines.append("  … \(entries.count - 80) more") }
                return PickerPanel.previewText(lines.joined(separator: "\n"))
            }), pane: pane)

        // 4. Scan the disk in the background, then refresh the list.
        guard box.scanning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = FolderIndex.scan(roots: [(current, 4), (home, 3)], limit: 15000, deadline: Date().addingTimeInterval(2.0))
            DispatchQueue.main.async { [weak picker] in
                Self.folderScan = (Date(), current, found)
                found.forEach { add($0, 0, nil) }
                box.scanning = false
                picker?.refresh()
            }
        }
    }

    /// Branches, most recent first. Enter switches; typing a new name offers to create it.
    func showBranchSwitcher(for pane: PaneView) {
        guard pane.session.gitBranch != nil else { NSSound.beep(); return }
        let current = pane.session.gitBranch ?? ""
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            let locals = await Generators.run("git_local_branches", cwd: pane.session.cwd, env: pane.session.env)
            let remotes = await Generators.run("git_remote_branches", cwd: pane.session.cwd, env: pane.session.env)
            let localNames = Set(locals.map(\.name))
            // Remote branches that already exist locally add nothing.
            let branches = locals + remotes.filter { r in !localNames.contains(String(r.name.split(separator: "/", maxSplits: 1).last ?? "")) }
            let remoteNames = Set(remotes.map(\.name))
            self?.presentPicker(PickerPanel.Config(
                title: "Switch branch  ·  on \(current)",
                placeholder: "Find a branch, or type a new name to create it…",
                scopes: ["All", "Local", "Remote"],
                hint: "⏎ switch   ⌥⏎ put name in editor   ⌘C copy name",
                provider: { query, scope in
                    var items: [PickerItem] = []
                    let q = query.trimmingCharacters(in: .whitespaces)
                    let known = Set(branches.map(\.name))
                    if !q.isEmpty, !known.contains(q), !q.contains(" ") {
                        items.append(PickerItem(title: "Create branch “\(q)”", subtitle: "git switch -c \(q)", accessory: "new",
                                                accessoryColor: .systemGreen, positions: [], payload: ("create", q)))
                    }
                    for b in branches {
                        let remote = remoteNames.contains(b.name) && !localNames.contains(b.name)
                        if scope == 1 && remote { continue }
                        if scope == 2 && !remote { continue }
                        guard let m = Fuzzy.match(q, b.name) else { continue }
                        let isCurrent = b.name == current
                        items.append(PickerItem(title: b.name, subtitle: b.description, accessory: isCurrent ? "● current" : (remote ? "remote" : nil),
                                                accessoryColor: isCurrent ? .systemGreen : nil, positions: m.positions, payload: ("switch", b.name)))
                    }
                    return items
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let (kind, name) = item.payload as? (String, String) else { return }
                    // "origin/feature" → switch to a local "feature" that tracks it.
                    let target = kind == "switch" && remoteNames.contains(name) && !localNames.contains(name)
                        ? String(name.split(separator: "/", maxSplits: 1).last ?? Substring(name)) : name
                    let cmd = kind == "create" ? "git switch -c " + ShellLexer.escape(target) : "git switch " + ShellLexer.escape(target)
                    if mods.contains(.option) { pane.insertIntoEditor(pane.editor.string + target); return }
                    if pane.session.atPrompt { pane.run(cmd) } else { NSSound.beep() }
                },
                onCopy: { item in (item.payload as? (String, String))?.1 },
                onDelete: nil,
                preview: { [weak pane] item in
                    guard let pane, let (kind, name) = item.payload as? (String, String) else { return nil }
                    if kind == "create" { return PickerPanel.previewText("Creates a new branch “\(name)” from \(current) and switches to it.") }
                    let log = await ScriptRunner.shared.run("git log --format='%h  %s  (%cr, %an)' -25 \(ShellLexer.escape(name)) --",
                                                            cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    let counts = await ScriptRunner.shared.run("git rev-list --left-right --count \(ShellLexer.escape(current))...\(ShellLexer.escape(name)) 2>/dev/null",
                                                               cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    var head = name
                    let parts = (counts ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                    if parts.count == 2, name != current { head += "  ·  \(parts[1]) ahead, \(parts[0]) behind \(current)" }
                    return PickerPanel.previewText(head + "\n\n" + (log ?? ""))
                }), pane: pane)
        }
    }

    /// Changed files in the repo: view the diff, stage/unstage, or open.
    func showChanges(for pane: PaneView) {
        guard pane.session.gitBranch != nil else { NSSound.beep(); return }
        Task { @MainActor [weak self, weak pane] in
            guard let pane else { return }
            let changes = await Generators.gitChanges(cwd: pane.session.cwd, env: pane.session.env)
            guard !changes.isEmpty else { NSSound.beep(); return }
            self?.presentPicker(PickerPanel.Config(
                title: "Changed files  ·  \(changes.count)",
                placeholder: "Filter changed files…",
                scopes: ["All", "Unstaged", "Staged"],
                hint: "⏎ show diff   ⌘⏎ stage / unstage   ⌥⏎ open in $EDITOR   ⌘C copy path",
                provider: { query, scope in
                    changes.compactMap { c in
                        if scope == 1 && c.staged && !c.untracked { return nil }
                        if scope == 2 && !c.staged { return nil }
                        guard let m = Fuzzy.match(query, c.path) else { return nil }
                        let color: NSColor = c.untracked ? .systemGreen : (c.code.contains("D") ? .systemRed : .systemOrange)
                        return PickerItem(title: c.path, subtitle: c.summary, accessory: c.code.trimmingCharacters(in: .whitespaces),
                                          accessoryColor: color, positions: m.positions, payload: c)
                    }
                },
                onAccept: { [weak pane] item, mods in
                    guard let pane, let c = item.payload as? GitChange else { return }
                    guard pane.session.atPrompt else { NSSound.beep(); return }
                    let f = ShellLexer.escape(c.path)
                    if mods.contains(.command) {
                        pane.run(c.staged ? "git restore --staged -- \(f)" : "git add -- \(f)")
                    } else if mods.contains(.option) {
                        pane.run("${VISUAL:-${EDITOR:-vi}} \(f)")
                    } else if c.untracked {
                        pane.run("cat -- \(f)")
                    } else {
                        pane.run(c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)")
                    }
                },
                onCopy: { ($0.payload as? GitChange)?.path },
                onDelete: nil,
                preview: { [weak pane] item in
                    guard let pane, let c = item.payload as? GitChange else { return nil }
                    let f = ShellLexer.escape(c.path)
                    if c.untracked {
                        let text = (try? String(contentsOfFile: (pane.session.cwd as NSString).appendingPathComponent(c.path), encoding: .utf8)) ?? "(binary or unreadable file)"
                        return PickerPanel.previewText("New file: \(c.path)\n\n" + String(text.prefix(20000)))
                    }
                    let diff = await ScriptRunner.shared.run(c.staged ? "git diff --cached -- \(f)" : "git diff -- \(f)",
                                                             cwd: pane.session.cwd, env: pane.session.env, timeout: 3)
                    return PickerPanel.previewText(diff ?? "", diff: true)
                }), pane: pane)
        }
    }

    func showClipboardHistory(for pane: PaneView) {
        let clip = Services.shared.clipboard
        presentPicker(PickerPanel.Config(
            title: "Clipboard",
            placeholder: "Search clipboard history…",
            scopes: [],
            hint: "⏎ insert   ⌘⏎ paste into terminal   ⌘C copy   ⌘⌫ remove",
            provider: { query, _ in
                clip.items.compactMap { item in
                    let oneLine = item.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    guard let m = Fuzzy.match(query, oneLine) else { return nil }
                    let lines = item.text.components(separatedBy: "\n").count
                    return PickerItem(title: String(oneLine.prefix(300)), subtitle: "\(Self.relative(item.date))\(lines > 1 ? " · \(lines) lines" : "") · \(item.text.count) chars",
                                      accessory: nil, accessoryColor: nil, positions: m.positions, payload: item.text)
                }
            },
            onAccept: { [weak pane] item, mods in
                guard let pane, let text = item.payload as? String else { return }
                if mods.contains(.command) || !pane.editorUsable { pane.surfaceView.sendText(text) } else { pane.insertIntoEditor(text) }
            },
            onCopy: { $0.payload as? String },
            onDelete: { item in if let t = item.payload as? String { clip.remove(t) } }), pane: pane)
    }

    func showCommandPalette(for pane: PaneView) {
        let cfg = Services.shared.config
        let shortcuts = AppDelegate.shared.shortcutLabels
        presentPicker(PickerPanel.Config(
            title: "Commands",
            placeholder: "Run an action or insert a snippet…",
            scopes: [],
            hint: "⏎ run",
            provider: { query, _ in
                var out: [(PickerItem, Int)] = []
                let recent = Self.recentActions
                for a in AnserAction.allCases {
                    if let m = Fuzzy.match(query, a.title) {
                        // Recently used actions float to the top.
                        let boost = recent.firstIndex(of: a.rawValue).map { 400 - $0 * 40 } ?? 0
                        let accessory = shortcuts[a] ?? (boost > 0 ? "recent" : nil)
                        out.append((PickerItem(title: a.title, subtitle: boost > 0 && query.isEmpty ? "recently used" : nil, accessory: accessory,
                                               accessoryColor: nil, positions: m.positions, payload: a), m.score + 5 + boost))
                    }
                }
                for s in cfg.snippets {
                    if let m = Fuzzy.match(query, s.name) ?? Fuzzy.match(query, s.command) {
                        out.append((PickerItem(title: s.name, subtitle: s.command, accessory: "snippet", accessoryColor: .systemYellow, positions: Fuzzy.match(query, s.name)?.positions ?? [], payload: s), m.score))
                    }
                }
                return out.sorted { $0.1 > $1.1 }.map(\.0)
            },
            onAccept: { [weak pane] item, _ in
                guard let pane else { return }
                if let a = item.payload as? AnserAction { Self.noteRecentAction(a); AppDelegate.shared.perform(a, pane: pane) }
                if let s = item.payload as? AnserConfig.Snippet { pane.insertIntoEditor(s.command) }
            },
            onCopy: { item in (item.payload as? AnserConfig.Snippet)?.command },
            onDelete: nil), pane: pane)
    }

    static var recentActions: [String] { UserDefaults.standard.stringArray(forKey: "AnserRecentActions") ?? [] }

    static func noteRecentAction(_ a: AnserAction) {
        guard ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil else { return }
        var list = recentActions.filter { $0 != a.rawValue }
        list.insert(a.rawValue, at: 0)
        UserDefaults.standard.set(Array(list.prefix(8)), forKey: "AnserRecentActions")
    }

    func showPicker(_ config: PickerPanel.Config, pane: PaneView) { presentPicker(config, pane: pane) }

    /// Like presentPicker, but returns the panel (for live updates).
    @discardableResult
    private func presentPickerReturning(_ config: PickerPanel.Config, pane: PaneView) -> PickerPanel? {
        presentPicker(config, pane: pane)
        return picker
    }

    private func presentPicker(_ config: PickerPanel.Config, pane: PaneView) {
        picker?.close()
        guard let window else { return }
        let p = PickerPanel(config: config)
        p.onClose = { [weak self, weak pane] in
            self?.picker = nil
            pane?.focus()
        }
        picker = p
        p.present(over: window)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func relative(_ d: Date) -> String {
        if d.timeIntervalSince1970 < 1 { return "imported" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func shortPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
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
