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

    /// Your editor ("openFilesWith", else the first of Cursor, VS Code, Zed… found), if it's a window app.
    static func guiEditor(env: ShellEnvironment) -> String? {
        let configured = Services.shared.config.openFilesWith?.trimmingCharacters(in: .whitespaces)
        let editor = (configured?.isEmpty == false ? configured : nil) ?? PathLink.guiEditors.first { CommandIndex.shared.contains($0, env: env) }
        guard let editor, !PathLink.terminalEditors.contains((editor as NSString).lastPathComponent) else { return nil }
        return editor
    }

    /// Opens a file or folder in your editor; false when there's no window editor (the caller can fall back).
    @discardableResult
    static func openInEditor(_ path: String, env: ShellEnvironment) -> Bool {
        guard let editor = guiEditor(env: env) else { return false }
        Services.shared.record("files.editor")
        if Services.isSelfTest { lastEditorLaunch = [editor, path]; return true }
        Task.detached {
            _ = await ScriptRunner.shared.run(argv: ["/usr/bin/env", editor, path], cwd: (path as NSString).deletingLastPathComponent, env: env, timeout: 10)
        }
        return true
    }
    /// For tests: what "Open in Editor" would have launched.
    static var lastEditorLaunch: [String] = []

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
        let env = pane.session.env
        if guiEditor(env: env) != nil { add("Open in Editor", "chevron.left.forwardslash.chevron.right") { openInEditor(path, env: env) } }
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
