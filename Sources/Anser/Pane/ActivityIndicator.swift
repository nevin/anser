import AppKit

/// Shows that a command is running. It spins for the first few seconds, then
/// settles into a still dot: a dev server or an agent can run for hours, and a
/// spinner redraws every frame the whole time. It never spins in a hidden window.
final class ActivityIndicator: NSView {
    /// How long it spins before settling.
    static let spinFor: TimeInterval = 8

    private let spinner = NSProgressIndicator()
    private let dot = NSView()
    private var settleWork: DispatchWorkItem?
    private var startedAt: Date?
    private var occlusionObserver: NSObjectProtocol?

    var running = false {
        didSet {
            guard running != oldValue else { return }
            startedAt = running ? Date() : nil
            settleWork?.cancel()
            if running {
                let w = DispatchWorkItem { [weak self] in self?.update() }
                settleWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinFor, execute: w)
            }
            update()
        }
    }

    /// Whether it's spinning right now (for tests).
    private(set) var isSpinning = false

    init(controlSize: NSControl.ControlSize) {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = controlSize
        spinner.isDisplayedWhenStopped = false
        dot.wantsLayer = true
        dot.isHidden = true
        addSubview(spinner)
        addSubview(dot)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        spinner.frame = bounds
        let d = (min(bounds.width, bounds.height) * 0.45).rounded()
        dot.frame = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        dot.layer?.cornerRadius = d / 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        if let w = window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: w, queue: .main) { [weak self] _ in self?.update() }
        }
        update()
    }

    override var isHidden: Bool { didSet { update() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDotColor()
    }

    private func updateDotColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }
    }

    private func update() {
        let fresh = startedAt.map { Date().timeIntervalSince($0) < Self.spinFor - 0.05 } ?? false
        let visible = window?.occlusionState.contains(.visible) ?? false
        let spin = running && fresh && visible && !isHidden
        if spin != isSpinning {
            isSpinning = spin
            if spin { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
        // While it would spin but the window is hidden, nothing needs drawing; once settled, a still dot.
        dot.isHidden = !running || fresh
        if !dot.isHidden { updateDotColor() }
    }

    deinit {
        settleWork?.cancel()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
    }
}
