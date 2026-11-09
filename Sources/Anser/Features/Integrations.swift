import AppKit
import AnserCore

/// Links and services other apps use: `anser://` (Shortcuts, Raycast, Alfred,
/// scripts) and Finder's Services menu ("New Anser Tab Here").
extension AppDelegate {
    func handleAnserLink(_ url: URL) {
        guard let link = AnserLink.parse(url) else { refuseLink(url); return }
        var dir = link.dir
        if let d = dir {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue else {
                let a = NSAlert()
                a.messageText = "That folder doesn't exist"
                a.informativeText = d
                a.runModal()
                return
            }
        } else {
            dir = nil
        }
        Services.shared.record("link." + link.action.rawValue)
        switch link.action {
        case .new:
            if link.newWindow { NSApp.activate(ignoringOtherApps: true); newWindow(cwd: dir) } else { openTab(cwd: dir, run: nil) }
        case .run:
            guard let cmd = link.command else { return }
            // Any web page can open a link, so a command always asks first.
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Run this command from a link?"
            a.informativeText = "\(cmd)\n\nin \(dir.map { PathDisplay.short($0) } ?? "your home folder")\n\nOnly run it if you started this from an app or shortcut you trust."
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Run in New Tab")
            if a.runModal() == .alertSecondButtonReturn { openTab(cwd: dir, run: cmd) }
        }
    }

    /// Finder → Services → New Anser Tab Here (folders, or a file's folder).
    @objc func newTabHere(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { error.pointee = "No folder selected" as NSString; return }
        for u in urls.prefix(8) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            openTab(cwd: isDir.boolValue ? u.path : u.deletingLastPathComponent().path, run: nil)
        }
        Services.shared.record("service.newTab")
    }

    func syncHistoryNow(pane: PaneView) {
        guard Services.shared.config.syncHistory else {
            let a = NSAlert()
            a.messageText = "History sync is off"
            a.informativeText = "Turn on “Share command history between my Macs” in Settings → Privacy & History. History goes to \(PathDisplay.short(HistorySyncService.shared.folder)); each Mac adds its own file there."
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { SettingsWindowController.shared.show(section: "Privacy & History") }
            return
        }
        HistorySyncService.shared.syncNow { [weak pane] r in
            let macs = r.otherMacs.isEmpty ? "no other Macs yet" : "\(r.otherMacs.count) other Mac\(r.otherMacs.count == 1 ? "" : "s")"
            pane?.flash("History synced: sent \(r.sent), got \(r.received) · \(macs)")
        }
    }
}
