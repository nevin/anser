import AppKit

/// The see-through, blurred backdrop the floating popups (pickers, search,
/// shortcuts, AI help) use: the desktop and terminal show through, tinted
/// with the terminal's background so text stays readable on any theme.
enum OverlayBackground {
    /// A view to use as a panel's content view; add the panel's controls to it.
    /// Rounded when `cornerRadius` > 0 (borderless-looking panels); a titled
    /// panel already has the system's rounded corners, so pass 0 there.
    static func make(cornerRadius: CGFloat = 12) -> NSVisualEffectView {
        let t = GhosttyRuntime.shared.theme
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        if cornerRadius > 0 { fx.maskImage = mask(radius: cornerRadius) }

        // The theme's color over the blur, light enough that what's behind shows.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = t.background.withAlphaComponent(t.isDark ? 0.55 : 0.6).cgColor
        tint.layer?.cornerRadius = cornerRadius
        tint.layer?.borderWidth = cornerRadius > 0 ? 1 : 0
        tint.layer?.borderColor = t.foreground.withAlphaComponent(0.16).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: fx.leadingAnchor), tint.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            tint.topAnchor.constraint(equalTo: fx.topAnchor), tint.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        return fx
    }

    /// Makes `panel` see-through so the backdrop's blur and corners show.
    static func prepare(_ panel: NSWindow) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
    }

    /// Puts a finished panel's content on the overlay: the panel becomes
    /// see-through, its title bar shows the blur too, and the content stays
    /// below the title bar.
    static func install(in panel: NSWindow) {
        guard let content = panel.contentView, !(content is NSVisualEffectView) else { return }
        let fx = make(cornerRadius: 0)
        if panel.appearance == nil { panel.appearance = fx.appearance }
        let wasFullSize = panel.styleMask.contains(.fullSizeContentView)
        if panel.styleMask.contains(.titled) {
            panel.styleMask.insert(.fullSizeContentView)
            panel.titlebarAppearsTransparent = true
        }
        prepare(panel)
        panel.contentView = fx
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        // Content that already reached under the title bar keeps doing so.
        let top = wasFullSize ? fx.topAnchor : (panel.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? fx.topAnchor
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor), content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: top), content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
    }

    /// The background for text and tables inside an overlay: the theme, a little see-through.
    static var contentColor: NSColor { GhosttyRuntime.shared.theme.background.withAlphaComponent(0.6) }

    private static func mask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 1, height: radius * 2 + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
