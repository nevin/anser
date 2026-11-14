import AppKit
import AnserCore

/// Broadcast input, profiles, merge conflicts and the output viewer.
extension TerminalWindowController {

    // MARK: Type in all panes

    func isBroadcasting(_ pane: PaneView) -> Bool { tab(for: pane)?.broadcasting ?? false }

    func panes(inSameTabAs pane: PaneView) -> [PaneView] {
        guard let tab = tab(for: pane), let i = tabs.firstIndex(where: { $0 === tab }) else { return [pane] }
        return panes(inTab: i)
    }

    /// Shell → Type in All Panes: commands run from the editor go to every pane in the tab.
    func toggleBroadcast(for pane: PaneView) {
        guard let tab = tab(for: pane) else { return }
        let all = panes(inSameTabAs: pane)
        if !tab.broadcasting, all.count < 2 {
            pane.flash("Split the tab first (⌘D): this sends commands to every pane in it")
            return
        }
        tab.broadcasting.toggle()
        Services.shared.record("broadcast.toggle")
        all.forEach { $0.refreshChrome() }
        pane.flash(tab.broadcasting ? "Commands now run in all \(all.count) panes" : "Back to this pane only")
    }

    // MARK: Profiles

    /// A pane's profile changed: the tab takes the first pane's profile color.
    func paneProfileChanged(_ pane: PaneView) {
        guard let tab = tab(for: pane), let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let color = panes(inTab: i).compactMap { $0.profile?.tabColor }.first
        guard tab.profileColor != color else { return }
        tab.profileColor = color
        tabBar.reload()
    }

    // MARK: Merge conflicts

    func showConflicts(for pane: PaneView) {
        let cwd = pane.session.cwd, env = pane.session.env
        guard pane.session.gitBranch != nil, !pane.session.isRemote else { pane.flash("Not in a git repository"); return }
        Services.shared.record("git.conflicts")
        Task { @MainActor [weak self, weak pane] in
            let porcelain = await ScriptRunner.shared.run("git status --porcelain 2>/dev/null", cwd: cwd, env: env, timeout: 4) ?? ""
            guard let self, let pane else { return }
            let conflicts = GitInfo.parseConflicts(porcelain)
            let op = GitInfo.gitDir(for: cwd).flatMap(GitInfo.operation(gitDir:))
            guard !conflicts.isEmpty || op != nil else { pane.flash("No merge conflicts here"); return }
            self.presentConflicts(conflicts, op: op, pane: pane)
        }
    }

    private enum ConflictAction { case file(GitInfo.Conflict), proceed(GitInfo.Operation), abort(GitInfo.Operation) }

    private func presentConflicts(_ conflicts: [GitInfo.Conflict], op: GitInfo.Operation?, pane: PaneView) {
        // In a rebase "ours" is the branch being rebased onto, so "mine" is --theirs.
        let mine = op == .rebase ? "--theirs" : "--ours"
        let theirs = op == .rebase ? "--ours" : "--theirs"
        let env = pane.session.env, cwd = pane.session.cwd
        showPicker(PickerPanel.Config(
            title: op.map { "\($0.title) in progress · \(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s")" } ?? "Merge conflicts",
            placeholder: "Filter files…",
            scopes: [],
            hint: "⏎ open in editor   ⌘⏎ mark resolved   ⌥⏎ keep mine   ⇧⏎ keep theirs",
            provider: { query, _ in
                var items: [PickerItem] = conflicts.compactMap { c in
                    guard let m = Fuzzy.match(query, c.path) else { return nil }
                    return PickerItem(title: c.path, subtitle: c.kind, accessory: "conflict", accessoryColor: .systemRed,
                                      positions: m.positions, payload: ConflictAction.file(c))
                }
                if let op, query.isEmpty {
                    if conflicts.isEmpty {
                        items.insert(PickerItem(title: "Continue the \(op.title.lowercased())", subtitle: "git \(op.command) --continue",
                                                accessory: "all resolved", accessoryColor: .systemGreen, positions: [], payload: ConflictAction.proceed(op), proportional: true), at: 0)
                    }
                    items.append(PickerItem(title: "Abort the \(op.title.lowercased())", subtitle: "git \(op.command) --abort: go back to before it started",
                                            accessory: nil, accessoryColor: nil, positions: [], payload: ConflictAction.abort(op), proportional: true))
                }
                return items
            },
            onAccept: { [weak pane] item, mods in
                guard let pane, pane.session.atPrompt || !(item.payload is ConflictAction) else { NSSound.beep(); return }
                switch item.payload as? ConflictAction {
                case .file(let c)?:
                    let f = ShellLexer.escape(c.path)
                    if mods.contains(.command) { pane.run("git add -- \(f)") }
                    else if mods.contains(.option) { pane.run("git checkout \(mine) -- \(f) && git add -- \(f)") }
                    else if mods.contains(.shift) { pane.run("git checkout \(theirs) -- \(f) && git add -- \(f)") }
                    else { FileActions.openInEditor(PathLink(path: c.path), pane: pane) }
                case .proceed(let op)?: pane.run("git \(op.command) --continue")
                case .abort(let op)?: pane.run("git \(op.command) --abort")
                case nil: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak pane] in pane?.refreshGitExtras() }
            },
            onCopy: { item in
                if case .file(let c)? = item.payload as? ConflictAction { return c.path }
                return nil
            },
            onDelete: nil,
            preview: { item in
                guard case .file(let c)? = item.payload as? ConflictAction else { return nil }
                let text = await ScriptRunner.shared.run("git diff -- \(ShellLexer.escape(c.path))", cwd: cwd, env: env, timeout: 4) ?? ""
                return PickerPanel.previewText(text.isEmpty ? "No diff to show (\(c.kind))." : text, diff: true)
            }), pane: pane)
    }

    // MARK: Output viewer

    /// Shows a command's whole output in its own window: scroll, find (⌘F), copy, export.
    func showOutputViewer(for pane: PaneView, block i: Int) {
        guard pane.session.blocks.indices.contains(i) else { NSSound.beep(); return }
        let b = pane.session.blocks[i]
        let out = pane.output(ofBlock: i) ?? ""
        Services.shared.record("output.viewer")
        OutputViewer(command: b.command, output: out, exitCode: b.exitCode, onExport: { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.exportOutput(for: pane, block: i)
        }).show(over: window)
    }
}

extension PaneView {
    /// Redraws the status row (after broadcast or a profile changes).
    func refreshChrome() { sessionDidUpdateInfo(session) }
}

/// A command's output in a window of its own: searchable, copyable, exportable.
final class OutputViewer: NSPanel {
    private static var open: [OutputViewer] = []
    private let textView = NSTextView()
    private let output: String

    init(command: String, output: String, exitCode: Int?, onExport: @escaping () -> Void) {
        self.output = output
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow], backing: .buffered, defer: false)
        title = "$ " + command.replacingOccurrences(of: "\n", with: " ")
        isReleasedWhenClosed = false
        let t = GhosttyRuntime.shared.theme
        appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)

        let lines = output.components(separatedBy: "\n").count
        let info = NSTextField(labelWithString: "\(lines) line\(lines == 1 ? "" : "s")" + (exitCode.map { $0 == 0 ? " · succeeded" : " · exit \($0)" } ?? "") + "   ·   ⌘F to find")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let copy = ClosureButton(title: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(output, forType: .string)
        }
        let export = ClosureButton(title: "Export…", run: onExport)
        let top = NSStackView(views: [info, NSView(), copy, export])
        top.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = t.foreground
        textView.backgroundColor = t.background
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = output.isEmpty ? "(no output)" : output
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = t.background

        let stack = NSStackView(views: [top, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        top.setContentHuggingPriority(.required, for: .vertical)
        contentView = stack
    }

    var text: String { output }

    func show(over parent: NSWindow?) {
        Self.open.append(self)
        if let f = parent?.frame { setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY - frame.height / 2)) } else { center() }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textView)
    }

    override func close() {
        super.close()
        Self.open.removeAll { $0 === self }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// Open viewers (for tests).
    static var openViewers: [OutputViewer] { open }
}
