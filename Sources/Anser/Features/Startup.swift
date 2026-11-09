import Foundation
import Darwin

/// Times startup, from the process starting to the first prompt, so slow
/// launches show up in the log and in Help → Report a Problem.
enum Startup {
    private static var marks: [(String, Double)] = []
    private static var done = false
    /// The last launch's timings ("services 40ms · terminal engine 120ms … first prompt 640ms").
    private(set) static var summary = ""

    /// When the process started (from the kernel), so time before main() counts too.
    static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }()

    static func mark(_ name: String) {
        guard !done else { return }
        marks.append((name, Date().timeIntervalSince1970))
    }

    static func firstPrompt() {
        guard !done else { return }
        mark("first prompt")
        done = true
        var last = processStart
        summary = marks.map { name, t in
            defer { last = t }
            return "\(name) +\(Int((t - last) * 1000))ms"
        }.joined(separator: " · ") + " = \(Int(((marks.last?.1 ?? last) - processStart) * 1000))ms"
        Diagnostics.shared.log("startup: " + summary)
    }

    static var totalMilliseconds: Int? {
        guard done, let end = marks.last?.1 else { return nil }
        return Int((end - processStart) * 1000)
    }
}
