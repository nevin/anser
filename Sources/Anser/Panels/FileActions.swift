import AppKit
import Quartz
import AnserCore

/// Opening a folder or file from a picker: Finder, your editor, its default
/// app, or Quick Look. Runnable things (apps, scripts) are only ever revealed.
enum FileActions {
    static func isFolder(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    static func reveal(_ path: String) {
        Services.shared.record("files.reveal")
        if isFolder(path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    /// Its default app, for documents. Apps, scripts and other runnable files are revealed instead.
    static func openDefault(_ path: String) {
        Services.shared.record("files.open")
        if isFolder(path) || OpenSafety.canOpenDirectly(path: path) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else { reveal(path) }
    }

    static func editorName(_ editor: String) -> String {
        let name = (editor as NSString).lastPathComponent
        return ["code": "VS Code", "cursor": "Cursor", "zed": "Zed", "subl": "Sublime Text",
                "codium": "VSCodium", "windsurf": "Windsurf", "idea": "IntelliJ IDEA", "nvim": "Neovim",
                "vim": "Vim", "nano": "Nano", "hx": "Helix"][name] ?? name
    }

    static func isTerminalEditor(_ editor: String) -> Bool {
        PathLink.terminalEditors.contains((editor as NSString).lastPathComponent)
    }

    static func automaticEditor(env: ShellEnvironment) -> String? {
        PathLink.guiEditors.first { CommandIndex.shared.contains($0, env: env) }
    }

    static func preferredEditor(env: ShellEnvironment) -> String? {
        if let configured = Services.shared.config.openFilesWith?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty { return configured }
        return automaticEditor(env: env)
    }

    static func editorTitle(for pane: PaneView) -> String {
        guard let editor = preferredEditor(env: pane.session.env) else { return "Choose Editor…" }
        return "Open in " + editorName(editor) + (isTerminalEditor(editor) ? " in This Pane" : "")
    }

    static func chooseEditor(for link: PathLink, pane: PaneView) {
        guard let window = pane.window, !pane.session.isRemote else { return }
        let env = pane.session.env
        let commands = [preferredEditor(env: env)].compactMap { $0 }
            + PathLink.guiEditors + PathLink.terminalEditors.sorted()
        var seen = Set<String>()
        let available = commands.filter { seen.insert($0).inserted && editorExists($0, env: env) }
        guard !available.isEmpty else {
            showEditorFailure("No editor was found on this pane’s PATH.", link: link, pane: pane)
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 26))
        popup.addItems(withTitles: available.map { editorName($0) + (isTerminalEditor($0) ? " in This Pane" : "") })
        popup.setAccessibilityLabel("Editor")
        if let preferred = preferredEditor(env: env), let index = available.firstIndex(of: preferred) {
            popup.selectItem(at: index)
        }
        let alert = NSAlert()
        alert.messageText = "Open With"
        alert.informativeText = link.path
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak pane] response in
            guard response == .alertFirstButtonReturn, let pane,
                  available.indices.contains(popup.indexOfSelectedItem) else { return }
            openInEditor(link, pane: pane, editor: available[popup.indexOfSelectedItem])
        }
    }

    private static func editorExists(_ editor: String, env: ShellEnvironment) -> Bool {
        if editor.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: editor) }
        return CommandIndex.shared.contains(editor, env: env)
    }

    static func openInEditor(_ link: PathLink, pane: PaneView, editor chosen: String? = nil) {
        guard !pane.session.isRemote else { return }
        let path = link.resolved(cwd: pane.session.cwd)
        let link = PathLink(path: path, line: link.line, column: link.column)
        let env = pane.session.env
        guard FileManager.default.fileExists(atPath: path) else {
            showEditorFailure("This file or folder no longer exists.", link: link, pane: pane)
            return
        }
        guard let editor = chosen ?? preferredEditor(env: env) else { chooseEditor(for: link, pane: pane); return }
        let terminal = isTerminalEditor(editor)
        let argv = isFolder(path) ? [editor, path] : link.editorCommand(editor, absolutePath: path)
        pane.lastOpenAction = "editor"
        pane.lastOpenedArgv = argv
        Services.shared.record("files.editor")
        if Services.isSelfTest { return }
        guard editorExists(editor, env: env) else {
            showEditorFailure("\(editorName(editor)) isn’t available in this pane.", link: link, pane: pane)
            return
        }
        if terminal {
            guard pane.session.atPrompt else {
                pane.flash("Wait for the shell prompt to open \(editorName(editor)) in this pane")
                return
            }
            pane.run(argv.map { "'" + ShellLexer.escape($0, insideQuote: "'") + "'" }.joined(separator: " "))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.currentDirectoryURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = env.pathString
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let message = "\(editorName(editor)) couldn’t open this item."
        process.terminationHandler = { [weak pane] process in
            guard process.terminationStatus != 0 else { return }
            DispatchQueue.main.async {
                if let pane { showEditorFailure(message, link: link, pane: pane) }
            }
        }
        do { try process.run() }
        catch { showEditorFailure(message, link: link, pane: pane) }
    }

    private static func showEditorFailure(_ message: String, link: PathLink, pane: PaneView) {
        guard let window = pane.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = link.path
        alert.addButton(withTitle: "Choose Editor")
        alert.addButton(withTitle: "Copy Path")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SettingsWindowController.shared.show(section: "Suggestions & Helpers") }
            if response == .alertSecondButtonReturn { copyPath(link.path) }
        }
    }

    static func openProject(for pane: PaneView) {
        guard !pane.session.isRemote else { pane.flash("Open Project in Editor is available for local folders"); return }
        guard let window = pane.window else { return }
        let cwd = pane.session.cwd
        let env = pane.session.env
        Task { [weak pane] in
            let result = await ScriptRunner.shared.runWithStatus(argv: ["/usr/bin/git", "rev-parse", "--show-toplevel"],
                cwd: cwd, env: env, timeout: 2)
            guard let pane, pane.window === window, !pane.session.isRemote else { return }
            let root = result.output.trimmingCharacters(in: .newlines)
            guard result.status == 0, root.hasPrefix("/"), isFolder(root) else {
                openInEditor(PathLink(path: cwd), pane: pane)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Open Project in Editor"
            alert.informativeText = root
            alert.addButton(withTitle: "Open Project")
            alert.addButton(withTitle: "Open Current Folder")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak pane] response in
                guard let pane else { return }
                if response == .alertFirstButtonReturn { openInEditor(PathLink(path: root), pane: pane) }
                if response == .alertSecondButtonReturn { openInEditor(PathLink(path: cwd), pane: pane) }
            }
        }
    }

    static func quickLook(_ path: String) {
        Services.shared.record("files.quicklook")
        QuickLookController.shared.show(URL(fileURLWithPath: path))
    }

    static func copyPath(_ path: String) { TerminalWindowController.copy(path) }

    /// cd there in this pane (or a new tab when something is running here).
    static func cdHere(_ path: String, pane: PaneView) {
        if pane.session.atPrompt, !pane.session.isRemote { pane.run("cd " + ShellLexer.escape(path)) }
        else { pane.windowController?.addTab(cwd: path) }
    }

    /// The right-click menu for a folder: the folder chip under the editor, sidebar folders.
    static func folderMenu(_ path: String, pane: PaneView) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ symbol: String, _ run: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, action: run)
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            m.addItem(i)
        }
        let here = path == pane.session.cwd
        add(here ? "cd Here (you're here)" : "cd Here", "arrow.right.circle") { [weak pane] in if let pane { cdHere(path, pane: pane) } }
        m.items.last?.isEnabled = !here
        add("New Tab Here", "plus.rectangle.on.rectangle") { [weak pane] in pane?.windowController?.addTab(cwd: path) }
        add("New Window Here", "macwindow.badge.plus") { AppDelegate.shared.newWindow(cwd: path) }
        add("Open in Finder", "folder") { reveal(path) }
        add("Copy Path", "doc.on.clipboard") { copyPath(path) }
        m.addItem(.separator())
        let link = PathLink(path: path)
        add(editorTitle(for: pane), "chevron.left.forwardslash.chevron.right") { [weak pane] in
            if let pane { openInEditor(link, pane: pane) }
        }
        if here {
            add("Open Project in Editor…", "folder") { [weak pane] in
                if let pane { openProject(for: pane) }
            }
        }
        add("Open With…", "ellipsis.circle") { [weak pane] in
            if let pane { chooseEditor(for: link, pane: pane) }
        }
        add("Quick Look", "eye") { quickLook(path) }
        // ClosureMenuItems handle their own enabling.
        m.autoenablesItems = false
        Services.shared.record("folderMenu")
        return m
    }

    /// A folder's contents for a "Files" submenu: subfolders first, hidden files left out.
    static func contents(of folder: String, limit: Int = 40) -> [(name: String, path: String, folder: Bool)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }
        let items = names.map { n -> (String, String, Bool) in let p = (folder as NSString).appendingPathComponent(n); return (n, p, isFolder(p)) }
        return items.sorted { $0.2 != $1.2 ? $0.2 : $0.0.localizedStandardCompare($1.0) == .orderedAscending }.prefix(limit).map { $0 }
    }
}

/// Shows the system Quick Look panel for one file.
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private(set) var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}
