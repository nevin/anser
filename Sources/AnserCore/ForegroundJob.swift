import Darwin

/// What a local shell is running in front right now: the terminal's foreground
/// process group (a command, and a pager it opened, like `git branch` → `less`).
/// Used to give pagers the whole window and to stop programs that ignore ⌃C.
public enum ForegroundJob {
    public struct Info: Sendable, Equatable {
        public let pgid: pid_t
        public let names: [String]
    }

    /// The job in front of `shellPID`'s terminal, or nil when the shell itself is
    /// in front (at its prompt) or the pid isn't a shell on a terminal.
    public static func of(shellPID: pid_t) -> Info? {
        guard shellPID > 1, let shell = kinfo(shellPID) else { return nil }
        // Only Anser's own shells: started by the anser-session helper or by Anser itself.
        // (A pid reported over ssh belongs to another machine and must never match here.)
        let parent = shell.kp_eproc.e_ppid
        guard parent == getpid() || name(parent) == "anser-session" else { return nil }
        let tty = shell.kp_eproc.e_tdev
        let front = shell.kp_eproc.e_tpgid
        guard tty != -1, front > 1, front != shellPID, front != getpgrp() else { return nil }
        // Only processes on the same terminal: never another app's process group.
        let members = pids(inGroup: front).filter { kinfo($0)?.kp_eproc.e_tdev == tty }
        guard !members.isEmpty else { return nil }
        return Info(pgid: front, names: members.compactMap(name))
    }

    /// Sends `signal` to the whole job (the command and anything it started in front).
    @discardableResult
    public static func send(_ signal: Int32, to job: Info) -> Bool {
        guard job.pgid > 1, job.pgid != getpgrp() else { return false }
        return kill(-job.pgid, signal) == 0
    }

    /// Pagers: they wait for a key and ignore ⌃C, so Stop ends them directly.
    public static let pagers: Set<String> = ["less", "more", "most", "pg", "man", "delta", "bat"]

    public static func isPager(_ job: Info) -> Bool { job.names.contains { pagers.contains($0) } }

    // MARK: Process info

    static func kinfo(_ pid: pid_t) -> kinfo_proc? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return kp
    }

    static func pids(inGroup group: pid_t) -> [pid_t] {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard bytes > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 16)
        let got = buf.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        return buf.prefix(Int(got) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    static func name(_ pid: pid_t) -> String? {
        var b = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &b, UInt32(b.count))
        return n > 0 ? String(cString: b) : nil
    }
}
