import AppKit
import AnserCore

extension TerminalWindowController {
    struct Workspace: Codable {
        let name: String
        let tabs: [SavedTab]
        let selected: Int
        var pinned: Bool? = nil
        var lastOpened: Date? = nil

        var badge: String { pinned == true ? "Pinned" : "Workspace" }

        static func ordered(_ workspaces: [Workspace]) -> [Workspace] {
            workspaces.filter { !$0.tabs.isEmpty }.sorted { lhs, rhs in
                if (lhs.pinned == true) != (rhs.pinned == true) { return lhs.pinned == true }
                if lhs.lastOpened != rhs.lastOpened {
                    return (lhs.lastOpened ?? .distantPast) > (rhs.lastOpened ?? .distantPast)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }

        var preview: String {
            func outline(_ layout: Layout, indent: String) -> [String] {
                switch layout {
                case let .pane(cwd, _, _): return [indent + PathDisplay.short(cwd, max: 100)]
                case let .split(vertical, children, _):
                    return [indent + (vertical ? "Side by side" : "Stacked")] +
                        children.flatMap { outline($0, indent: indent + "  ") }
                }
            }
            return tabs.enumerated().map { index, tab in
                (["Tab \(index + 1)" + (tab.title.map { " · " + $0 } ?? "")] +
                 outline(tab.layout, indent: "  ")).joined(separator: "\n")
            }.joined(separator: "\n\n")
        }

        static var fileURL: URL { AnserConfig.directory.appendingPathComponent("workspaces.json") }

        static func load(from url: URL = fileURL) throws -> [Workspace] {
            do {
                return try JSONDecoder().decode([Workspace].self, from: Data(contentsOf: url))
            } catch CocoaError.fileReadNoSuchFile {
                return []
            }
        }

        static func save(_ workspaces: [Workspace], to url: URL = fileURL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(workspaces).write(to: url, options: .atomic)
        }
    }

    func workspaceSnapshot(named name: String) -> Workspace {
        Workspace(name: name, tabs: snapshotTabs(includeSession: false), selected: selectedIndex)
    }

    func promptToSaveWorkspace() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Window as Workspace"
        alert.informativeText = "Save the tabs, splits, and folders in this window. Anser focuses the workspace if it is already open."
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "Workspace name"
        nameField.setAccessibilityLabel("Workspace name")
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { self.focusedPane?.flash("Enter a workspace name"); return }
            do {
                let exists = try Workspace.load().contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                if exists {
                    let confirm = NSAlert()
                    confirm.messageText = "Replace “\(name)”?"
                    confirm.informativeText = "The workspace will use this window's current layout."
                    confirm.addButton(withTitle: "Cancel")
                    confirm.addButton(withTitle: "Replace")
                    confirm.beginSheetModal(for: window) { [weak self] response in
                        if response == .alertSecondButtonReturn { self?.saveWorkspace(named: name) }
                    }
                } else {
                    self.saveWorkspace(named: name)
                }
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    private func saveWorkspace(named name: String) {
        do {
            var saved = try Workspace.load()
            var workspace = workspaceSnapshot(named: name)
            if let index = saved.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                workspace.pinned = saved[index].pinned
                workspace.lastOpened = saved[index].lastOpened
                saved[index] = workspace
            } else {
                saved.append(workspace)
            }
            try Workspace.save(saved)
            if !isQuickTerminal, Self.openWindow(forWorkspace: name) == nil {
                workspaceName = name
            }
            focusedPane?.flash("Saved workspace “\(name)”")
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    static func openWindow(forWorkspace name: String) -> TerminalWindowController? {
        AppDelegate.shared.tabWindows.first {
            $0.workspaceName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    func openWorkspace(_ name: String, from url: URL = Workspace.fileURL) {
        do {
            var saved = try Workspace.load(from: url)
            guard let index = saved.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  !saved[index].tabs.isEmpty else { NSSound.beep(); return }
            saved[index].lastOpened = Date()
            let workspace = saved[index]
            do { try Workspace.save(saved, to: url) }
            catch { Diagnostics.shared.log("Could not update recent workspaces") }

            if let existing = Self.openWindow(forWorkspace: name), let window = existing.window {
                NSApp.activate(ignoringOtherApps: true)
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
                existing.focusedPane?.focus()
                return
            }

            let controller = TerminalWindowController(tabs: workspace.tabs, selected: workspace.selected, frame: nil)
            controller.workspaceName = workspace.name
            AppDelegate.shared.adopt(controller)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    func showWorkspaces(for pane: PaneView, from url: URL = Workspace.fileURL) {
        var saved: [Workspace]
        do { saved = Workspace.ordered(try Workspace.load(from: url)) }
        catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }

        showPicker(PickerPanel.Config(
            title: "Open Workspace",
            placeholder: "Search saved workspaces…",
            scopes: [],
            hint: saved.isEmpty ? "Use Window → Save Window as Workspace to create one" : "Return · Open workspace",
            provider: { query, _ in
                saved.compactMap { workspace in
                    guard let match = Fuzzy.match(query, workspace.name) else { return nil }
                    let count = workspace.tabs.count
                    return PickerItem(title: workspace.name,
                                      subtitle: workspace.lastOpened.map { "Opened " + Self.relative($0) },
                                      accessory: Self.openWindow(forWorkspace: workspace.name) != nil ? "Open" : (workspace.pinned == true ? "Pinned" : "\(count) tabs"),
                                      accessoryColor: nil, positions: match.positions, payload: workspace, proportional: true)
                }
            },
            onAccept: { [weak self] item, _ in
                if let workspace = item.payload as? Workspace { self?.openWorkspace(workspace.name, from: url) }
            },
            onCopy: nil,
            onDelete: nil,
            preview: { item in
                (item.payload as? Workspace).map { PickerPanel.previewText($0.preview) }
            },
            actions: [
                .init(title: "Pin", symbol: "pin", applies: { ($0.payload as? Workspace)?.pinned != true },
                      closesPicker: false, run: { [weak self] item in
                    if let workspace = item.payload as? Workspace { updatePin(workspace.name, pinned: true, controller: self) }
                }),
                .init(title: "Unpin", symbol: "pin.slash", applies: { ($0.payload as? Workspace)?.pinned == true },
                      closesPicker: false, run: { [weak self] item in
                    if let workspace = item.payload as? Workspace { updatePin(workspace.name, pinned: false, controller: self) }
                }),
            ],
            selectionHint: { item in
                guard let workspace = item.payload as? Workspace else { return "Return · Open workspace" }
                return Self.openWindow(forWorkspace: workspace.name) != nil ? "Return · Focus open window" : "Return · Open in a new window"
            },
            showsActionMenu: true), pane: pane)

        func updatePin(_ name: String, pinned: Bool, controller: TerminalWindowController?) {
            do {
                var latest = try Workspace.load(from: url)
                guard let index = latest.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
                latest[index].pinned = pinned
                try Workspace.save(latest, to: url)
                saved = Workspace.ordered(latest)
                if let picker = controller?.picker {
                    picker.refresh()
                    if let row = picker.itemTitles.firstIndex(of: latest[index].name) { picker.selectRow(row) }
                }
            } catch {
                if let window = controller?.picker { NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }
}
