import AppKit

/// Help → Take the Tour: five short pages on the things that make Anser easier, each with a "Show Me".
final class TourWindowController: NSWindowController {
    static let shared = TourWindowController()

    struct Page { var symbol: String; var title: String; var text: String; var showMe: String?; var action: (() -> Void)? }

    let pages: [Page] = [
        Page(symbol: "character.cursor.ibeam", title: "Type in a real editor",
             text: "The box at the bottom is an editor: click anywhere, select with the mouse, use several cursors, paste many lines. Gray text completes from your history; → accepts it. Tab completes commands, flags, files and branches.",
             showMe: nil, action: nil),
        Page(symbol: "cursorarrow.click.2", title: "Right-click any command",
             text: "Right-click a command or its output for everything you can do with it: run it again, copy the output, compare with the last run, save it to the Notebook, make an alias, watch it, share it.",
             showMe: nil, action: nil),
        Page(symbol: "circle.grid.2x1.left.filled", title: "The status row speaks in colors",
             text: "Under the editor: red means something went wrong, orange that something is waiting, blue is information, green a suggestion. Suggestions fade after a while; “+N” holds the rest. Click any chip.",
             showMe: nil, action: nil),
        Page(symbol: "square.grid.2x2", title: "Find anything",
             text: "⌘R searches everything: history, this tab, what commands printed, every tab and your saved commands (⇥ changes where). ⇧⌘P finds any action by what it does (“typo”, “port”, “record”). ⌥⌘O opens the Library, where your notebook, aliases and history are managed.",
             showMe: "Open the Library", action: { LibraryWindowController.shared.show(for: nil) }),
        Page(symbol: "sidebar.left", title: "Keep things one click away",
             text: "The sidebar (⌃⌘S) shows git changes, servers, project tasks, failed tests, containers and more. Right-click a heading to move or hide it, so it shows what you use.",
             showMe: "Show the Sidebar", action: { AppDelegate.shared.toggleSidebar(nil) }),
    ]

    private(set) var index = 0
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let dots = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let next = NSButton(title: "Next", target: nil, action: nil)
    private let showMe = NSButton(title: "", target: nil, action: nil)

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Anser Tour"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        index = 0
        render()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Services.shared.record("tour.open")
    }

    private func build() {
        guard let content = window?.contentView else { return }
        icon.symbolConfiguration = .init(pointSize: 34, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .secondaryLabelColor
        textLabel.preferredMaxLayoutWidth = 420
        dots.font = .systemFont(ofSize: 11)
        dots.textColor = .tertiaryLabelColor
        for (b, sel) in [(back, #selector(backTapped)), (next, #selector(nextTapped)), (showMe, #selector(showMeTapped))] {
            b.target = self; b.action = sel; b.bezelStyle = .rounded
        }
        next.keyEquivalent = "\r"
        let buttons = NSStackView(views: [dots, NSView(), showMe, back, next])
        buttons.spacing = 8
        let stack = NSStackView(views: [icon, titleLabel, textLabel, NSView(), buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 18, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56).isActive = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    func render() {
        let p = pages[index]
        icon.image = NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil)
        titleLabel.stringValue = p.title
        textLabel.stringValue = p.text
        dots.stringValue = "\(index + 1) of \(pages.count)"
        back.isEnabled = index > 0
        next.title = index == pages.count - 1 ? "Done" : "Next"
        showMe.isHidden = p.showMe == nil
        showMe.title = p.showMe ?? ""
    }

    var currentTitle: String { pages[index].title }

    @objc func nextTapped() {
        if index == pages.count - 1 { close(); return }
        index += 1
        render()
    }

    @objc func backTapped() {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func showMeTapped() { pages[index].action?() }
}
