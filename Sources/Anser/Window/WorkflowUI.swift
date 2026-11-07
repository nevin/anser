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
            hint: "⏎ run   ⌥⏎ put in editor   ⌘⏎ edit file   ⌘⌫ move to Trash",
            provider: { query, scope in
                workflows.compactMap { w in
                    if scope == 1 && w.source != .project { return nil }
                    if scope == 2 && w.source != .personal { return nil }
                    guard let m = Fuzzy.match(query, w.name) ?? (w.description.flatMap { Fuzzy.match(query, $0) }) else { return nil }
                    let params = w.allParams.map(\.name)
                    let sub = [w.description, "\(w.steps.count) step\(w.steps.count == 1 ? "" : "s")", params.isEmpty ? nil : "asks for " + params.joined(separator: ", ")]
                        .compactMap { $0 }.joined(separator: " · ")
                    let trusted = WorkflowTrust().isTrusted(w)
                    return PickerItem(title: w.name, subtitle: sub, accessory: w.source == .project ? (trusted ? "project" : "project · untrusted") : nil,
                                      accessoryColor: trusted ? .systemTeal : .systemOrange, positions: Fuzzy.match(query, w.name)?.positions ?? [], payload: w,
                                      proportional: true)
                } + (query.isEmpty || "new workflow".contains(query.lowercased())
                     ? [PickerItem(title: "New workflow…", subtitle: "Save commands from this tab as a reusable workflow", accessory: nil,
                                   accessoryColor: nil, positions: [], payload: NewWorkflowRow(), proportional: true)] : [])
            },
            onAccept: { [weak self, weak pane] item, mods in
                guard let self, let pane else { return }
                if item.payload is NewWorkflowRow { self.showSaveWorkflow(for: pane); return }
                guard let w = item.payload as? Workflow else { return }
                if mods.contains(.command), let f = w.file { NSWorkspace.shared.open(f); return }
                // Putting it in the editor runs nothing, so only running needs trust.
                self.startWorkflow(w, in: pane, insertOnly: mods.contains(.option))
            },
            onCopy: { ($0.payload as? Workflow)?.render([:]) },
            onDelete: { [weak self] item in
                // Personal workflows only (a project's belong to the repo); the Trash keeps a copy.
                guard let w = item.payload as? Workflow, let f = w.file else { return }
                guard w.source == .personal else { NSSound.beep(); return }
                do {
                    try FileManager.default.trashItem(at: f, resultingItemURL: nil)
                    self?.picker?.close()
                    self?.focusedPane?.flash("Moved “\(w.name)” to the Trash")
                } catch { NSSound.beep() }
            },
            preview: { item in
                if item.payload is NewWorkflowRow {
                    return Self.workflowPreview(nil)
                }
                guard let w = item.payload as? Workflow else { return nil }
                return Self.workflowPreview(w)
            }), pane: pane)
    }

    /// The picker's right-hand side: description, numbered steps with
    /// parameters shown as chips, parameters, trust, and where it's saved.
    static func workflowPreview(_ w: Workflow?) -> NSAttributedString {
        let t = GhosttyRuntime.shared.theme
        let body = NSFont.systemFont(ofSize: 12)
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont = body, _ color: NSColor = t.foreground.withAlphaComponent(0.85), _ extra: [NSAttributedString.Key: Any] = [:]) {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            a.merge(extra) { $1 }
            out.append(NSAttributedString(string: s, attributes: a))
        }
        func heading(_ s: String) { add(s.uppercased() + "\n", .systemFont(ofSize: 10, weight: .semibold), t.dim) }
        guard let w else {
            add("Turn commands you ran in this tab into a workflow you can run again with one keystroke.\n\n")
            add("Use {{name}} in a step to ask for a value each time, or {{name:default}} to pre-fill it.", body, t.dim)
            return out
        }
        if let d = w.description { add(d + "\n\n") }
        heading("Steps")
        let placeholder = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_\-]+)\s*(?::([^}]*))?\}\}"#)
        for (i, step) in w.steps.enumerated() {
            add("\(i + 1)  ", mono, t.dim)
            let ns = step as NSString
            var last = 0
            for m in placeholder.matches(in: step, range: NSRange(location: 0, length: ns.length)) {
                add(ns.substring(with: NSRange(location: last, length: m.range.location - last)), mono)
                let name = ns.substring(with: m.range(at: 1))
                add(" \(name) ", .monospacedSystemFont(ofSize: 11, weight: .semibold), t.blue, [.backgroundColor: t.blue.withAlphaComponent(0.16)])
                last = m.range.location + m.range.length
            }
            add(ns.substring(from: last) + "\n", mono)
        }
        let params = w.allParams
        if !params.isEmpty {
            add("\n")
            heading("Asks for")
            for p in params {
                add(" \(p.name) ", .monospacedSystemFont(ofSize: 11, weight: .semibold), t.blue, [.backgroundColor: t.blue.withAlphaComponent(0.16)])
                var detail = ""
                if let o = p.options { detail += "  one of " + o.joined(separator: ", ") }
                if let d = p.default { detail += detail.isEmpty ? "  default \(d)" : " (default \(d))" }
                add(detail + "\n", body, t.dim)
            }
        }
        add("\n")
        add(((w.stopOnError ?? true) ? "Stops at the first failing step." : "Runs every step even if one fails.") + "\n", body, t.dim)
        if w.source == .project {
            let trusted = WorkflowTrust().isTrusted(w)
            add(trusted ? "✓ Trusted: it runs straight away.\n" : "⚠︎ Not trusted yet: you'll see its steps and confirm before it runs.\n",
                .systemFont(ofSize: 12, weight: .medium), trusted ? t.green : .systemOrange)
        }
        if let f = w.file {
            add((w.source == .project ? "Shared with the repo: " : "Personal: ") + PathDisplay.short(f.path, max: 40) + "\n", body, t.dim)
        }
        return out
    }

    /// Asks before the first run of a project workflow (or after it changed),
    /// showing exactly what it will run.
    func confirmTrust(_ w: Workflow, then done: @escaping (Bool) -> Void) {
        guard !WorkflowTrust().isTrusted(w) else { done(true); return }
        let a = trustAlert(w)
        let respond: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn { WorkflowTrust().trust(w); done(true) } else { done(false) }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: respond) } else { respond(a.runModal()) }
    }

    func trustAlert(_ w: Workflow) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Run “\(w.name)” from this project?"
        let steps = w.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        a.informativeText = "This workflow came with the repository (\(w.file?.lastPathComponent ?? "unknown file")), not from you. "
            + "It is new or changed since you last trusted it. It will run:\n\n\(steps.prefix(1500))"
        a.addButton(withTitle: "Trust & Run")
        a.addButton(withTitle: "Cancel")
        return a
    }

    /// Runs one workflow: trust check (project ones), values, then run. With
    /// `insertOnly`, puts the filled-in command in the editor instead.
    func startWorkflow(_ w: Workflow, in pane: PaneView, insertOnly: Bool = false) {
        Services.shared.record("workflow.run")
        let insert = insertOnly || !pane.session.atPrompt
        let go = {
            self.askParameters(w, pane: pane) { values in
                guard let values else { return }
                if insert { pane.insertIntoEditor(w.render(values)) } else { self.runWorkflow(w, values: values, in: pane) }
            }
        }
        if insert { go() } else { confirmTrust(w) { if $0 { go() } } }
    }

    /// Runs a saved notebook command. One with {{values}} asks for them first,
    /// like a workflow (the notebook is where both live now).
    func runNotebookEntry(_ e: Notebook.Entry, in pane: PaneView) {
        Services.shared.record("notebook.run")
        let w = Workflow(name: e.displayTitle, description: e.note.isEmpty ? nil : e.note, steps: [e.command])
        guard !w.allParams.isEmpty else { pane.run(e.command); pane.focus(); return }
        askParameters(w, pane: pane) { [weak pane] values in
            guard let pane, let values else { return }
            pane.run(w.render(values))
            pane.focus()
        }
    }

    func runWorkflow(_ w: Workflow, values: [String: String], in pane: PaneView) {
        // Last line of defence for any caller that skipped the prompt.
        guard WorkflowTrust().isTrusted(w) else { Diagnostics.shared.log("blocked untrusted project workflow"); NSSound.beep(); return }
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

/// The "New workflow…" entry at the end of the workflow picker.
struct NewWorkflowRow {}
