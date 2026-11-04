import AppKit
import Darwin
import MetricKit

/// Crash, hang and activity logging, all kept locally in ~/Library/Logs/Anser.
/// Nothing is sent anywhere; Help → Report a Problem lets you review and share it.
final class Diagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = Diagnostics()

    static let directory: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Anser")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var logURL: URL { directory.appendingPathComponent("anser.log") }
    /// Written by the crash handler; renamed on the next launch.
    static var pendingCrashURL: URL { directory.appendingPathComponent("crash-pending.log") }

    private let queue = DispatchQueue(label: "anser.diagnostics", qos: .utility)
    private var breadcrumbs: [String] = []
    private let lock = NSLock()
    private var lastMainPing = Date()
    private var hangStart: Date?
    /// A crash log from the previous run, if there was one.
    private(set) var previousCrash: URL?

    // MARK: Start

    func start() {
        rotateLogIfNeeded()
        collectPreviousCrash()
        installCrashHandlers()
        startHangWatchdog()
        MXMetricManager.shared.add(self)
        let info = Bundle.main.infoDictionary
        log("Launch: Anser \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?")), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    // MARK: Logging

    /// Appends a line to anser.log and to the in-memory breadcrumb trail.
    func log(_ message: String) {
        let line = "\(Self.timestamp()) \(message)"
        lock.withLock {
            breadcrumbs.append(line)
            if breadcrumbs.count > 300 { breadcrumbs.removeFirst(breadcrumbs.count - 300) }
        }
        queue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: Self.logURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: Self.logURL)
            }
        }
    }

    var recentBreadcrumbs: [String] { lock.withLock { breadcrumbs } }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func rotateLogIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: Self.logURL.path))?[.size] as? Int, size > 2_000_000 else { return }
        let old = Self.directory.appendingPathComponent("anser.old.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: Self.logURL, to: old)
    }

    // MARK: Crashes

    private func collectPreviousCrash() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.pendingCrashURL.path) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dest = Self.directory.appendingPathComponent("crash-\(f.string(from: Date())).log")
        try? fm.moveItem(at: Self.pendingCrashURL, to: dest)
        previousCrash = dest
    }

    private func installCrashHandlers() {
        // The handler may only use async-signal-safe calls, so the path is prepared now.
        crashPathCString = strdup(Self.pendingCrashURL.path)
        crashFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
        for (sig, name) in [(SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"), (SIGILL, "SIGILL"), (SIGABRT, "SIGABRT"), (SIGFPE, "SIGFPE"), (SIGTRAP, "SIGTRAP")] {
            crashHeaders[Int(sig)] = strdup("Anser crashed: \(name)\n")
        }
        NSSetUncaughtExceptionHandler { e in
            let text = "Uncaught exception: \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.joined(separator: "\n") + "\n"
            try? text.write(to: Diagnostics.pendingCrashURL, atomically: false, encoding: .utf8)
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = anserCrashSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(sig, &action, nil)
        }
    }

    // MARK: Hangs

    /// A background thread checks that the main thread answers at least once
    /// every 3 seconds; long stalls are logged with how long they lasted.
    private func startHangWatchdog() {
        let t = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let self else { return }
                DispatchQueue.main.async { self.lock.withLock { self.lastMainPing = Date() } }
                let since = Date().timeIntervalSince(self.lock.withLock { self.lastMainPing })
                if since > 3, self.hangStart == nil {
                    self.hangStart = Date().addingTimeInterval(-since)
                    self.log("HANG: main thread unresponsive for \(Int(since))s")
                } else if since < 1.5, let start = self.hangStart {
                    self.hangStart = nil
                    self.log(String(format: "HANG ended after %.1fs", Date().timeIntervalSince(start)))
                }
            }
        }
        t.name = "Anser hang watchdog"
        t.qualityOfService = .utility
        t.start()
    }

    // MARK: MetricKit (system crash/hang reports with stacks, delivered later)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for (i, p) in payloads.enumerated() {
            let url = Self.directory.appendingPathComponent("system-diagnostic-\(Int(Date().timeIntervalSince1970))-\(i).json")
            try? p.jsonRepresentation().write(to: url)
            log("Saved system diagnostic report \(url.lastPathComponent)")
        }
    }

    // MARK: Reports

    /// Everything useful for a bug report, as text the user can review.
    func makeReport(description: String) -> String {
        let info = Bundle.main.infoDictionary
        var r: [String] = []
        r.append("# Anser problem report")
        r.append("")
        r.append("What happened: \(description.isEmpty ? "(not described)" : description)")
        r.append("")
        r.append("## System")
        r.append("- Anser \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))")
        r.append("- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        r.append("- Shell: \(ShellSession.userShell)")
        r.append("- Screens: \(NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height))@\($0.backingScaleFactor)x" }.joined(separator: ", "))")
        r.append("- Windows: \(NSApp.windows.filter { $0.windowController is TerminalWindowController }.count)")
        r.append("")
        let crashes = ((try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let latest = crashes.first, let text = try? String(contentsOf: latest, encoding: .utf8) {
            r.append("## Most recent crash (\(latest.lastPathComponent))")
            r.append("```")
            r.append(String(text.prefix(12000)))
            r.append("```")
            r.append("")
        }
        r.append("## Recent activity")
        r.append("```")
        r.append(recentBreadcrumbs.suffix(150).joined(separator: "\n"))
        r.append("```")
        return r.joined(separator: "\n")
    }
}

// MARK: - Signal handler (async-signal-safe only)

// Prepared at startup: no allocation is allowed inside the handler.
private var crashPathCString: UnsafeMutablePointer<CChar>?
private var crashFrames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
private var crashHeaders = [UnsafeMutablePointer<CChar>?](repeating: nil, count: 32)

private func anserCrashSignalHandler(_ sig: Int32) {
    if let path = crashPathCString, let frames = crashFrames {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            if sig >= 0, sig < 32, let h = crashHeaders[Int(sig)] { write(fd, h, strlen(h)) }
            let n = backtrace(frames, 128)
            backtrace_symbols_fd(frames, n, fd)
            close(fd)
        }
    }
    // Let the default handler finish (so macOS also writes its report).
    signal(sig, SIG_DFL)
    raise(sig)
}
