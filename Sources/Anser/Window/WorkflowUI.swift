import AppKit
import AnserCore

/// Workflows (run, save) and Markdown export for a window's panes.
extension TerminalWindowController {

    // MARK: Run

    func showWorkflows(for pane: PaneView) {
        let workflows = WorkflowStore.load(cwd: pane.session.cwd)
        guard !workflows.isEmpty else {
            let a = NSAlert()
            a.messageText = "No workflows yet"
            a.informativeText = "A workflow is a saved multi-step command with {{parameters}}. Create one from this tab's commands with Shell → Save Commands as Workflow…, or add JSON files to ~/.config/anser/workflows (personal) or .anser/workflows in a repo (shared with your team)."
            a.addButton(withTitle: "Save Commands as Workflow…")
            a.addButton(withTitle: "OK")
            if let w = window {
                a.beginSheetModal(for: w) { [weak self, weak pane] r in
                    if r == .alertFirstButtonReturn, let pane { self?.showSaveWorkflow(for: pane) }
                }
            }
            return
        }
        presentWorkflowPicker(workflows, pane: pane)
    }

    private func presentWorkflowPicker(_ workflows: [Workflow], pane: PaneView) {
        showPicker(PickerPanel.Config(
            title: "Workflows",
            placeholder: "Find a workflow…",
            scopes: ["All", "This project", "Personal"],
            hint: "⏎ run   ⌥⏎ put in editor   ⌘⏎ edit file",
            provider: { query, scope in
                workflows.compactMap { w in
                    if scope == 1 && w.source != .project { return nil }
                    if scope == 2 && w.source != .personal { return nil }
                    guard let m = Fuzzy.match(query, w.name) ?? (w.description.flatMap { Fuzzy.match(query, $0) }) else { return nil }
                    let params = w.allParams.map(\.name)
                    let sub = [w.description, "\(w.steps.count) step\(w.steps.count == 1 ? "" : "s")", params.isEmpty ? nil : "asks for " + params.joined(separator: ", ")]
                        .compactMap { $0 }.joined(separator: " · ")
                    return PickerItem(title: w.name, subtitle: sub, accessory: w.source == .project ? "project" : nil,
                                      accessoryColor: .systemTeal, positions: Fuzzy.match(query, w.name)?.positions ?? [], payload: w)
                }
            },
            onAccept: { [weak self, weak pane] item, mods in
                guard let self, let pane, let w = item.payload as? Workflow else { return }
                if mods.contains(.command), let f = w.file { NSWorkspace.shared.open(f); return }
                self.askParameters(w, pane: pane) { values in
                    guard let values else { return }
                    let cmd = w.render(values)
                    if mods.contains(.option) || !pane.session.atPrompt { pane.insertIntoEditor(cmd) } else { self.runWorkflow(w, values: values, in: pane) }
                }
            },
            onCopy: { ($0.payload as? Workflow)?.render([:]) },
            onDelete: nil,
            preview: { item in
                guard let w = item.payload as? Workflow else { return nil }
                var lines: [String] = []
                if let d = w.description { lines += [d, ""] }
                for (i, s) in w.steps.enumerated() { lines.append("\(i + 1). \(s)") }
                let params = w.allParams
                if !params.isEmpty {
                    lines += ["", "Parameters:"]
                    for p in params {
                        var l = "  \(p.name)"
                        if let d = p.default { l += " (default: \(d))" }
                        if let o = p.options { l += " — one of: " + o.joined(separator: ", ") }
                        lines.append(l)
                    }
                }
                lines += ["", (w.stopOnError ?? true) ? "Stops at the first failing step." : "Runs every step even if one fails."]
                if let f = w.file { lines += ["", w.source == .project ? "Shared: \(f.path)" : "Personal: \(f.path)"] }
                return PickerPanel.previewText(lines.joined(separator: "\n"))
            }), pane: pane)
    }

    func runWorkflow(_ w: Workflow, values: [String: String], in pane: PaneView) {
        Diagnostics.shared.log("workflow run: \(w.steps.count) steps")
        pane.run(w.render(values))
    }

    /// A form for the workflow's parameters (dropdowns where options are given).
    func makeParameterForm(_ w: Workflow) -> (view: NSView, values: () -> [String: String]) {
        var getters: [(String, () -> String)] = []
        var rows: [[NSView]] = []
        for p in w.allParams {
            let label = NSTextField(labelWithString: p.name + ":")
            label.alignment = .right
            let control: NSView
            if let options = p.options, !options.isEmpty {
                let popup = NSPopUpButton()
                popup.addItems(withTitles: options)
                if let d = p.default, options.contains(d) { popup.selectItem(withTitle: d) }
                control = popup
                getters.append((p.name, { popup.titleOfSelectedItem ?? "" }))
            } else {
                let field = NSTextField(string: p.default ?? "")
                field.placeholderString = p.description ?? p.name
                field.widthAnchor.constraint(equalToConstant: 260).isActive = true
                control = field
                getters.append((p.name, { field.stringValue }))
            }
            rows.append([label, control])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame.size = grid.fittingSize
        return (grid, { Dictionary(getters.map { ($0.0, $0.1()) }, uniquingKeysWith: { a, _ in a }) })
    }

    func askParameters(_ w: Workflow, pane: PaneView, done: @escaping ([String: String]?) -> Void) {
        guard !w.allParams.isEmpty, let window else { done([:]); return }
        let form = makeParameterForm(w)
        let a = NSAlert()
        a.messageText = w.name
        a.informativeText = w.description ?? "Fill in the values, then Run."
        a.accessoryView = form.view
        a.addButton(withTitle: "Run")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in done(r == .alertFirstButtonReturn ? form.values() : nil) }
    }

    // MARK: Save

    func showSaveWorkflow(for pane: PaneView) {
        let recent = Array(pane.session.blocks.suffix(15).reversed()).map(\.command).filter { !$0.isEmpty }
        guard !recent.isEmpty, let window else { NSSound.beep(); return }
        let name = NSTextField(string: "")
        name.placeholderString = "Name, e.g. Reset local database"
        let desc = NSTextField(string: "")
        desc.placeholderString = "What it does (optional)"
        let whereTo = NSPopUpButton()
        whereTo.addItem(withTitle: "Personal (~/.config/anser/workflows)")
        if WorkflowStore.projectDirectory(for: pane.session.cwd) != nil { whereTo.addItem(withTitle: "This project (.anser/workflows, share via git)") }
        let boxes = recent.reversed().map { cmd -> NSButton in
            let b = NSButton(checkboxWithTitle: cmd.count > 70 ? String(cmd.prefix(67)) + "…" : cmd, target: nil, action: nil)
            b.toolTip = cmd
            return b
        }
        boxes.last?.state = .on
        let list = NSStackView(views: boxes)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        let tip = NSTextField(wrappingLabelWithString: "Steps run in the order shown and stop at the first failure. After saving, replace values with {{name}} in the file to be asked for them each time.")
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.preferredMaxLayoutWidth = 440
        let stack = NSStackView(views: [name, desc, whereTo, NSTextField(labelWithString: "Steps:"), list, tip])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for f in [name, desc] { f.widthAnchor.constraint(equalToConstant: 440).isActive = true }
        stack.frame.size = stack.fittingSize

        let a = NSAlert()
        a.messageText = "Save commands as a workflow"
        a.accessoryView = stack
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        a.beginSheetModal(for: window) { [weak self, weak pane] r in
            guard r == .alertFirstButtonReturn, let self, let pane else { return }
            let steps = zip(recent.reversed(), boxes).filter { $0.1.state == .on }.map(\.0)
            let title = name.stringValue.trimmingCharacters(in: .whitespaces)
            guard !steps.isEmpty, !title.isEmpty else { NSSound.beep(); return }
            let project = whereTo.indexOfSelectedItem == 1 ? WorkflowStore.projectDirectory(for: pane.session.cwd) : nil
            let wf = Workflow(name: title, description: desc.stringValue.isEmpty ? nil : desc.stringValue, steps: steps)
            do {
                let url = try WorkflowStore.save(wf, to: project ?? WorkflowStore.personalDirectory)
                pane.flash("Saved workflow “\(title)”")
                Diagnostics.shared.log("workflow saved: \(url.lastPathComponent)")
            } catch {
                self.window.map { NSAlert(error: error).beginSheetModal(for: $0) }
            }
        }
    }

    // MARK: Markdown export

    /// This tab's commands with their output (where still in the scrollback).
    func markdown(for pane: PaneView) -> String {
        let blocks = pane.session.blocks
        // Commands typed with a leading space are private; leave them out.
        let entries = blocks.enumerated().filter { !$0.element.command.isEmpty }.map { i, b in
            MarkdownExport.Entry(command: b.command, cwd: b.cwd, exitCode: b.exitCode, duration: b.duration, started: b.started,
                                 output: pane.output(ofBlock: i))
        }
        let title = (tab(for: pane).map { self.title(of: $0) } ?? "Terminal") + " session"
        return MarkdownExport.render(title: title, entries: entries)
    }

    func exportMarkdown(for pane: PaneView, copy: Bool) {
        guard !pane.session.blocks.isEmpty else { NSSound.beep(); return }
        let md = markdown(for: pane)
        if copy {
            Self.copy(md)
            pane.flash("Copied \(pane.session.blocks.count) commands as Markdown")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (tab(for: pane).map { self.title(of: $0) } ?? "session") + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard let window else { return }
        panel.beginSheetModal(for: window) { r in
            if r == .OK, let url = panel.url { try? md.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
