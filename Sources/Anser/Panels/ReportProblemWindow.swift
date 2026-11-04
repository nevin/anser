import AppKit

/// Help → Report a Problem. Builds a report (system info, recent activity,
/// latest crash) that you review, then copy or save. Nothing is uploaded.
final class ReportProblemWindowController: NSWindowController {
    static let shared = ReportProblemWindowController()

    private let descriptionField = NSTextField()
    private let reportView = NSTextView()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Report a Problem"
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(crashed: Bool = false) {
        if crashed { descriptionField.placeholderString = "Anser quit unexpectedly. What were you doing just before?" }
        regenerate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let intro = NSTextField(wrappingLabelWithString: "Describe what went wrong. The report below is built on this Mac and never sent anywhere. Review it, then copy it into an email or issue. It includes recent activity (program names, not full commands) and the latest crash log.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        descriptionField.placeholderString = "What happened, and what did you expect?"
        descriptionField.target = self
        descriptionField.action = #selector(regenerate)

        reportView.isEditable = false
        reportView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        reportView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = reportView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        reportView.autoresizingMask = [.width]
        reportView.isVerticallyResizable = true

        let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyReport))
        copy.keyEquivalent = "\r"
        let save = NSButton(title: "Save…", target: self, action: #selector(saveReport))
        let logs = NSButton(title: "Show Logs in Finder", target: self, action: #selector(showLogs))
        let buttons = NSStackView(views: [logs, NSView(), save, copy])
        buttons.distribution = .fill

        let stack = NSStackView(views: [intro, descriptionField, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [intro, descriptionField, scroll, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        window?.contentView = stack
    }

    @objc private func regenerate() {
        reportView.string = Diagnostics.shared.makeReport(description: descriptionField.stringValue)
    }

    var reportText: String { reportView.string }

    @objc private func copyReport() {
        regenerate()
        TerminalWindowController.copy(reportView.string)
    }

    @objc private func saveReport() {
        regenerate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "anser-report.md"
        panel.beginSheetModal(for: window!) { [self] r in
            if r == .OK, let url = panel.url { try? reportView.string.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    @objc private func showLogs() { NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logURL]) }
}
