import AppKit
import AnserCore

/// Import from iTerm2 / Warp, and the local feature-usage view.
extension AppDelegate {

    // MARK: Import

    func importSettings() {
        let found = [Importers.iTerm2(), Importers.warp()].compactMap { $0 }
        guard !found.isEmpty else {
            let a = NSAlert()
            a.messageText = "Nothing to import"
            a.informativeText = "Anser looks for iTerm2's profiles (colors and font) and Warp's themes, workflows and font. Neither was found on this Mac."
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = "Import from \(found.map(\.source).joined(separator: " and "))"
        a.informativeText = "Themes become Ghostty themes you can pick in Settings → Appearance. Workflows become Command Notebook entries. Nothing is removed."
        var boxes: [(NSButton, Importers.Found)] = []
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for f in found {
            let b = NSButton(checkboxWithTitle: "\(f.source): \(f.summary)", target: nil, action: nil)
            b.state = .on
            stack.addArrangedSubview(b)
            boxes.append((b, f))
        }
        let apply = NSButton(checkboxWithTitle: "Also switch to its current theme and font", target: nil, action: nil)
        apply.state = found.contains { $0.currentTheme != nil || $0.fontFamily != nil } ? .on : .off
        stack.addArrangedSubview(apply)
        stack.frame.size = stack.fittingSize
        a.accessoryView = stack
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let chosen = boxes.filter { $0.0.state == .on }.map(\.1)
        let result = Self.performImport(chosen, applyLook: apply.state == .on)
        Services.shared.record("import." + chosen.map(\.source).joined(separator: "+"))
        let done = NSAlert()
        done.messageText = "Imported"
        done.informativeText = result
        done.runModal()
    }

    /// Writes themes, notebook entries and (optionally) the theme and font. Returns a summary.
    @discardableResult
    static func performImport(_ found: [Importers.Found], applyLook: Bool,
                              themesDir: String = SettingsWindowController.userThemesDir,
                              notebookURL: URL = NotebookWindow.fileURL) -> String {
        var lines: [String] = []
        try? FileManager.default.createDirectory(atPath: themesDir, withIntermediateDirectories: true)
        for f in found {
            for t in f.themes { try? t.text.write(toFile: themesDir + "/" + t.name, atomically: true, encoding: .utf8) }
            if !f.themes.isEmpty { lines.append("\(f.themes.count) theme\(f.themes.count == 1 ? "" : "s") from \(f.source)") }
            if !f.entries.isEmpty {
                var nb = (try? Notebook.load(from: notebookURL)) ?? Notebook()
                let have = Set(nb.allEntries.map(\.command))
                let fresh = f.entries.filter { !have.contains($0.command) }
                if !fresh.isEmpty {
                    let name = "From \(f.source)"
                    let g = nb.groups.first { $0.name == name }?.id ?? nb.addGroup(named: name)
                    for e in fresh { nb.add(e, to: g) }
                    try? nb.save(to: notebookURL)
                    Services.shared.notebookSaved()
                    NotificationCenter.default.post(name: .anserNotebookChanged, object: nil)
                }
                lines.append("\(fresh.count) workflow\(fresh.count == 1 ? "" : "s") into the notebook (\(f.entries.count - fresh.count) already there)")
            }
        }
        if applyLook, let f = found.first(where: { $0.currentTheme != nil || $0.fontFamily != nil }) {
            let builtIn = GhosttyRuntime.shared.resourcesDir.map { $0 + "/themes/" } ?? ""
            if let theme = f.currentTheme,
               FileManager.default.fileExists(atPath: themesDir + "/" + theme) || FileManager.default.fileExists(atPath: builtIn + theme) {
                SettingsWindowController.setValue(["appearance", "darkTheme"], theme)
                SettingsWindowController.setValue(["appearance", "theme"], nil)
                lines.append("Theme: \(theme)")
            }
            if let fam = f.fontFamily, NSFontManager.shared.availableFontFamilies.contains(fam) {
                SettingsWindowController.setValue(["appearance", "fontFamily"], fam)
                lines.append("Font: \(fam)")
            }
            if let size = f.fontSize { SettingsWindowController.setValue(["appearance", "fontSize"], size); lines.append("Text size: \(Int(size))pt") }
        }
        SettingsWindowController.shared.reloadThemes()
        return lines.isEmpty ? "Nothing new to bring over." : lines.map { "• " + $0 }.joined(separator: "\n")
    }

    // MARK: Usage

    func showUsage() {
        let a = NSAlert()
        if Services.shared.config.usageStats {
            a.messageText = "Your feature usage"
            a.informativeText = "Counted only on this Mac and never sent. Help → Report a Problem includes it so you can choose to share it."
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = Services.shared.usage.report()
            let scroll = NSScrollView(frame: text.frame)
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            a.accessoryView = scroll
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Copy")
            a.addButton(withTitle: "Turn Off and Clear")
            switch a.runModal() {
            case .alertSecondButtonReturn: TerminalWindowController.copy(Services.shared.usage.report())
            case .alertThirdButtonReturn:
                SettingsWindowController.setValue(["usageStats"], false)
                Services.shared.clearUsage()
            default: break
            }
        } else {
            a.messageText = "Usage counting is off"
            a.informativeText = "Anser can count which features you use (per day, for 90 days), kept only on this Mac. It helps decide what to improve when you choose to share it in a problem report."
            a.addButton(withTitle: "Turn On")
            a.addButton(withTitle: "Not Now")
            if a.runModal() == .alertFirstButtonReturn { SettingsWindowController.setValue(["usageStats"], true) }
        }
    }
}
