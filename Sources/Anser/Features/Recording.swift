import AppKit
import UniformTypeIdentifiers
import AnserCore

/// Records what a tab shows (the screen, several times a second, only when it
/// changes) plus where each command started.
final class TabRecorder {
    weak var pane: PaneView?
    private(set) var recording: TabRecording
    private let started = Date()
    private var timer: Timer?
    private var chipTick = 0
    static let maxSeconds: Double = 60 * 60
    static let maxBytes = 40 << 20

    var elapsed: Double { Date().timeIntervalSince(started) }

    init(pane: PaneView) {
        self.pane = pane
        recording = TabRecording(title: pane.displayTitle, started: started, columns: 0, rows: 0)
        capture()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.05
    }

    private func tick() {
        capture()
        chipTick += 1
        if chipTick % 5 == 0 { pane?.refreshBar() }
        if elapsed > Self.maxSeconds || recording.byteCount > Self.maxBytes {
            pane?.flash("Recording stopped: it reached its size limit")
            pane?.stopRecording()
        }
    }

    func capture() {
        guard let text = pane?.surfaceView.viewportText() else { return }
        let lines = text.components(separatedBy: "\n")
        recording.rows = max(recording.rows, lines.count)
        recording.columns = max(recording.columns, lines.map(\.count).max() ?? 0)
        recording.add(text, at: elapsed)
    }

    func mark(_ command: String) {
        recording.marks.append(TabRecording.Mark(t: elapsed, label: command))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        capture()
    }
}

enum RecordingStore {
    /// Tests use their own folder.
    static var directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Anser/recordings")

    static func save(_ r: TabRecording) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = r.title.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(40)
        let url = directory.appendingPathComponent("\(df.string(from: r.started)) \(String(safe)).anserrec")
        try r.encoded().write(to: url, options: .atomic)
        return url
    }
}

extension PaneView {
    func toggleRecording() { if recorder == nil { startRecording() } else { stopRecording() } }

    func startRecording() {
        guard recorder == nil else { return }
        recorder = TabRecorder(pane: self)
        Services.shared.record("record.start")
        flash("Recording this tab. Everything on screen is recorded until you stop.")
        refreshBar()
    }

    @discardableResult
    func stopRecording(open: Bool = true) -> URL? {
        guard let rec = recorder else { return nil }
        rec.stop()
        recorder = nil
        refreshBar()
        guard rec.recording.frames.count > 1 else { flash("Nothing changed on screen, so nothing was saved"); return nil }
        do {
            let url = try RecordingStore.save(rec.recording)
            Services.shared.record("record.stop")
            if open { ReplayWindowController.show(rec.recording, file: url) }
            return url
        } catch {
            flash("Couldn't save the recording: \(error.localizedDescription)")
            return nil
        }
    }

    func showRecordingMenu() {
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Stop and Replay") { [weak self] in self?.stopRecording() })
        m.addItem(ClosureMenuItem(title: "Discard Recording") { [weak self] in
            self?.recorder?.stop()
            self?.recorder = nil
            self?.refreshBar()
            self?.flash("Recording discarded")
        })
        m.popUp(positioning: nil, at: NSPoint(x: recChip.frame.minX, y: recChip.frame.maxY + 2), in: bar)
    }
}

/// Plays a recording back: play/pause, speed, skip idle time, jump to a command, export.
final class ReplayWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ReplayWindowController] = []

    let original: TabRecording
    let file: URL?
    private(set) var recording: TabRecording
    private(set) var time: Double = 0
    private(set) var playing = false
    private var timer: Timer?
    private var lastTick = Date()

    private let screen = NSTextView()
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "")
    private let speed = NSPopUpButton()
    private let skipIdle = NSButton(checkboxWithTitle: "Skip idle time", target: nil, action: nil)
    private let marks = NSPopUpButton()
    private let hideSecrets = NSButton(checkboxWithTitle: "Hide secrets when sharing", target: nil, action: nil)

    @discardableResult
    static func show(_ r: TabRecording, file: URL?) -> ReplayWindowController {
        let c = ReplayWindowController(r, file: file)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    static func forTests() -> ReplayWindowController? { open.last }

    static func openFile() {
        let p = NSOpenPanel()
        p.directoryURL = RecordingStore.directory
        p.allowedContentTypes = [UTType(filenameExtension: "anserrec") ?? .json]
        p.message = "Open a tab recording"
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let r = try TabRecording.decode(Data(contentsOf: url))
            show(r, file: url)
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't open the recording"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }

    init(_ r: TabRecording, file: URL?) {
        original = r
        recording = r.compressingIdle()
        self.file = file
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Replay · " + r.title
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 300)
        super.init(window: w)
        w.delegate = self
        build()
        w.center()
        seek(to: 0)
        Services.shared.record("record.replay")
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        Self.open.removeAll { $0 === self }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        let t = GhosttyRuntime.shared.theme
        screen.isEditable = false
        screen.isSelectable = true
        screen.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        screen.backgroundColor = t.background
        screen.textColor = t.foreground
        screen.textContainerInset = NSSize(width: 12, height: 10)
        screen.isHorizontallyResizable = true
        screen.textContainer?.widthTracksTextView = false
        screen.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = screen
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = t.background
        scroll.translatesAutoresizingMaskIntoConstraints = false

        playButton.bezelStyle = .rounded
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.setAccessibilityLabel("Play")
        playButton.toolTip = "Play / pause (space)"
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.keyEquivalent = " "
        slider.minValue = 0
        slider.maxValue = max(0.01, recording.duration)
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.isContinuous = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        speed.addItems(withTitles: ["0.5×", "1×", "2×", "4×", "8×"])
        speed.selectItem(at: 1)
        speed.controlSize = .small
        skipIdle.state = .on
        skipIdle.target = self
        skipIdle.action = #selector(idleToggled)
        skipIdle.controlSize = .small
        marks.controlSize = .small
        marks.target = self
        marks.action = #selector(markPicked)
        rebuildMarks()
        let controls = NSStackView(views: [playButton, slider, timeLabel, speed, skipIdle, marks])
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let export = NSPopUpButton(frame: .zero, pullsDown: true)
        export.addItem(withTitle: "Share")
        for (title, sel) in [("Export HTML Player…", #selector(exportHTML)), ("Export asciinema (.cast)…", #selector(exportCast)),
                             ("Trim: Start Here", #selector(trimStartHere)), ("Trim: End Here", #selector(trimEndHere)), ("Trim: Reset", #selector(trimReset)),
                             ("Copy This Screen as Text", #selector(copyScreen)), ("Show in Finder", #selector(revealFile))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            export.menu?.addItem(i)
        }
        export.controlSize = .small
        hideSecrets.state = .on
        hideSecrets.controlSize = .small
        hideSecrets.toolTip = "Blank out tokens, keys and passwords found on screen in exported files"
        let info = NSTextField(labelWithString: "\(original.frames.count) frames · \(Services.formatDuration(original.duration)) · \(original.marks.count) command\(original.marks.count == 1 ? "" : "s")")
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let foot = NSStackView(views: [info, NSView(), hideSecrets, export])
        foot.spacing = 8
        foot.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll); content.addSubview(controls); content.addSubview(foot)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            controls.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            foot.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            foot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            foot.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            foot.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    private func rebuildMarks() {
        marks.removeAllItems()
        marks.addItem(withTitle: recording.marks.isEmpty ? "No commands" : "Jump to command…")
        for m in recording.marks {
            marks.addItem(withTitle: Services.formatDuration(m.t) + "  " + String(m.label.prefix(60)))
        }
        marks.isEnabled = !recording.marks.isEmpty
    }

    // MARK: Playback

    var screenText: String { screen.string }

    func seek(to t: Double) {
        time = min(max(0, t), recording.duration)
        if let i = recording.frameIndex(at: time) {
            let text = recording.frames[i].text
            if screen.string != text { screen.string = text }
        }
        slider.doubleValue = time
        timeLabel.stringValue = Services.formatDuration(time) + " / " + Services.formatDuration(recording.duration)
    }

    @objc func togglePlay() {
        playing.toggle()
        if playing, time >= recording.duration { seek(to: 0) }
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: playing ? "Pause" : "Play")
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        timer?.invalidate()
        guard playing else { return }
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.advance() }
    }

    private var rate: Double { [0.5, 1, 2, 4, 8][max(0, speed.indexOfSelectedItem)] }

    private func advance() {
        let now = Date()
        seek(to: time + now.timeIntervalSince(lastTick) * rate)
        lastTick = now
        if time >= recording.duration { togglePlay() }
    }

    @objc private func scrubbed() { seek(to: slider.doubleValue) }

    @objc private func idleToggled() {
        // Keep the same frame on screen when switching.
        let frame = recording.frameIndex(at: time) ?? 0
        recording = skipIdle.state == .on ? trimmedOriginal.compressingIdle() : trimmedOriginal
        slider.maxValue = max(0.01, recording.duration)
        rebuildMarks()
        seek(to: recording.frames.indices.contains(frame) ? recording.frames[frame].t : 0)
    }

    @objc private func markPicked() {
        let i = marks.indexOfSelectedItem - 1
        guard recording.marks.indices.contains(i) else { return }
        seek(to: recording.marks[i].t)
    }

    // MARK: Sharing

    /// Trim points in the original recording's time (exports and the saved copy use them).
    private(set) var trimStart: Double = 0
    private(set) var trimEnd: Double?

    /// The current position in the original recording's time (idle skipping changes the clock).
    private var originalTime: Double {
        guard let i = recording.frameIndex(at: time), original.frames.indices.contains(i) else { return time }
        return original.frames[i].t
    }

    @objc func trimStartHere() { trimStart = originalTime; applyTrim() }
    @objc func trimEndHere() { trimEnd = originalTime; applyTrim() }
    @objc private func trimReset() { trimStart = 0; trimEnd = nil; applyTrim() }

    func setTrimForTests(start: Double, end: Double?) { trimStart = start; trimEnd = end; applyTrim() }

    private var trimmedOriginal: TabRecording {
        let end = trimEnd ?? original.duration
        return trimStart <= 0 && end >= original.duration ? original : original.trimmed(from: trimStart, to: end)
    }

    private func applyTrim() {
        let base = trimmedOriginal
        recording = skipIdle.state == .on ? base.compressingIdle() : base
        slider.maxValue = max(0.01, recording.duration)
        rebuildMarks()
        seek(to: 0)
        // Keep the trimmed copy as the saved recording.
        if let file, let d = try? base.encoded() { try? d.write(to: file, options: .atomic) }
        window?.title = "Replay · " + original.title + (base == original ? "" : " (trimmed to \(Services.formatDuration(base.duration)))")
    }

    private var shareable: TabRecording { hideSecrets.state == .on ? trimmedOriginal.redacted() : trimmedOriginal }

    private func save(_ text: String, ext: String) {
        guard let w = window else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        p.nameFieldStringValue = (file?.deletingPathExtension().lastPathComponent ?? original.title) + "." + ext
        p.beginSheetModal(for: w) { r in
            guard r == .OK, let url = p.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); NSWorkspace.shared.activateFileViewerSelecting([url]) }
            catch { NSSound.beep() }
        }
    }

    @objc private func exportHTML() {
        let t = GhosttyRuntime.shared.theme
        Services.shared.record("record.export.html")
        save(shareable.html(background: Self.hex(t.background), foreground: Self.hex(t.foreground)), ext: "html")
    }

    @objc private func exportCast() {
        Services.shared.record("record.export.cast")
        save(shareable.asciicast(), ext: "cast")
    }

    @objc private func copyScreen() { TerminalWindowController.copy(hideSecrets.state == .on ? AIHelp.redact(screen.string) : screen.string) }

    @objc private func revealFile() {
        if let file { NSWorkspace.shared.activateFileViewerSelecting([file]) } else { NSWorkspace.shared.open(RecordingStore.directory) }
    }

    static func hex(_ c: NSColor) -> String {
        guard let s = c.usingColorSpace(.sRGB) else { return "#1e1e1e" }
        return String(format: "#%02x%02x%02x", Int(s.redComponent * 255), Int(s.greenComponent * 255), Int(s.blueComponent * 255))
    }
}
