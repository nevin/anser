import Darwin
import Foundation

/// The processes your tabs started, read straight from the kernel: the tree
/// under each shell, CPU and memory, ports, and processes left behind by tabs
/// that have closed. Only your own processes are looked at.
public enum ProcessScan {
    public struct Proc: Sendable, Hashable {
        public var pid: pid_t
        public var ppid: pid_t
        public var pgid: pid_t
        public var uid: uid_t
        public var name: String
        public var started: Date
        /// Its controlling terminal (-1 for none).
        public var tty: Int32
        public init(pid: pid_t, ppid: pid_t, pgid: pid_t = 0, uid: uid_t = 0, name: String, started: Date = .distantPast, tty: Int32 = -1) {
            self.pid = pid; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.name = name; self.started = started; self.tty = tty
        }
    }

    /// A process in a tab's tree, with how deep it sits under the shell (1 = started by the shell).
    public struct Node: Sendable, Hashable {
        public var proc: Proc
        public var depth: Int
        public init(proc: Proc, depth: Int) { self.proc = proc; self.depth = depth }
    }

    /// Every process, in one sysctl call.
    public static func all() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard procs.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        return procs.prefix(size / stride).compactMap { kp in
            let pid = kp.kp_proc.p_pid
            guard pid > 0 else { return nil }
            var comm = kp.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let tv = kp.kp_proc.p_starttime
            return Proc(pid: pid, ppid: kp.kp_eproc.e_ppid, pgid: kp.kp_eproc.e_pgid, uid: kp.kp_eproc.e_ucred.cr_uid,
                        name: name, started: Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6), tty: kp.kp_eproc.e_tdev)
        }
    }

    /// What a shell is running as commands and jobs: on its terminal, outside its own process group.
    /// Leaves out the shell's helpers (a prompt's `$(git …)`, async prompt workers on a pty of their own).
    /// Processes younger than `minAge` are left for the next look: prompts start short-lived helpers all the time.
    public static func jobs(of shell: Proc, _ nodes: [Node], now: Date = Date(), minAge: TimeInterval = 1.5) -> [Node] {
        nodes.filter { n in
            n.proc.pgid != shell.pid && (shell.tty == -1 || n.proc.tty == shell.tty)
                && now.timeIntervalSince(n.proc.started) >= minAge && !isShellHelper(n.proc.name)
        }
    }

    /// Long-running helpers a shell's prompt starts for itself (powerlevel10k's git status daemon).
    public static func isShellHelper(_ name: String) -> Bool { name.hasPrefix("gitstatusd") }

    /// Each shell's processes, parents before their children, deepest at most `maxDepth`.
    public static func trees(under shells: [pid_t], in procs: [Proc], maxDepth: Int = 12) -> [pid_t: [Node]] {
        var children: [pid_t: [Proc]] = [:]
        for p in procs where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        for k in children.keys { children[k]?.sort { $0.started == $1.started ? $0.pid < $1.pid : $0.started < $1.started } }
        var out: [pid_t: [Node]] = [:]
        for shell in Set(shells) where shell > 1 {
            var list: [Node] = []
            var seen: Set<pid_t> = [shell]
            func walk(_ pid: pid_t, _ depth: Int) {
                guard depth <= maxDepth else { return }
                for c in children[pid] ?? [] where seen.insert(c.pid).inserted {
                    list.append(Node(proc: c, depth: depth))
                    walk(c.pid, depth + 1)
                }
            }
            walk(shell, 1)
            if !list.isEmpty { out[shell] = list }
        }
        return out
    }

    // MARK: CPU and memory

    public struct Usage: Sendable, Equatable {
        /// CPU time used so far, in nanoseconds.
        public var cpuNanos: UInt64
        /// Memory in use (resident), in bytes.
        public var memory: UInt64
    }

    public static func usage(_ pid: pid_t) -> Usage? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return Usage(cpuNanos: ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)), memory: info.pti_resident_size)
    }

    /// CPU times come in Mach ticks (not nanoseconds on Apple silicon).
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Percent of one core used between two readings (a busy multi-threaded program can pass 100).
    public static func cpuPercent(from a: Usage, to b: Usage, seconds: Double) -> Double {
        guard seconds > 0, b.cpuNanos >= a.cpuNanos else { return 0 }
        return Double(b.cpuNanos - a.cpuNanos) / (seconds * 1e9) * 100
    }

    // MARK: Paths, folders, arguments

    /// The full process name (the kernel's short name is cut at 16 characters).
    public static func name(_ pid: pid_t) -> String? { ForegroundJob.name(pid) }

    /// TCP ports `pid` is listening on.
    public static func ports(_ pid: pid_t) -> [ServerPorts.Listener] {
        var seen = Set<Int>()
        return ServerPorts.listeningPorts(pid).filter { seen.insert($0.port).inserted }.sorted { $0.port < $1.port }
            .map { ServerPorts.Listener(pid: pid, process: name(pid) ?? "process \(pid)", port: $0.port, address: $0.address) }
    }

    public static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    public static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        var p = info.pvi_cdir.vip_path
        let s = withUnsafeBytes(of: &p) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return s.isEmpty ? nil : s
    }

    public struct Arguments: Sendable, Equatable {
        public var executable: String
        public var args: [String]
        public var env: [String: String]
        /// The command line as typed, roughly ("node server.js --port 3000").
        public var commandLine: String { args.joined(separator: " ") }
    }

    /// A process's arguments and environment (your own processes only).
    public static func arguments(_ pid: pid_t) -> Arguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buf.prefix(size)))
    }

    /// Parses KERN_PROCARGS2: argc (Int32), the executable path, padding NULs, argv, then the environment.
    public static func parseProcArgs(_ bytes: [UInt8]) -> Arguments? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        func next() -> String? {
            guard i < bytes.count else { return nil }
            let start = i
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        guard let exe = next() else { return nil }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var args: [String] = []
        for _ in 0..<max(0, argc) { guard let a = next() else { break }; args.append(a) }
        var env: [String: String] = [:]
        while let e = next(), !e.isEmpty {
            if let eq = e.firstIndex(of: "=") { env[String(e[..<eq])] = String(e[e.index(after: eq)...]) }
        }
        return Arguments(executable: exe, args: args, env: env)
    }

    // MARK: Telling processes apart

    /// Part of macOS (ControlCenter on :5000 and :7000, rapportd…): listed but never stopped.
    public static func isSystem(path: String?) -> Bool {
        guard let path else { return true }
        return ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// "Docker" for anything inside Docker.app; nil outside an app.
    public static func appName(path: String?) -> String? {
        guard let path, let r = path.range(of: ".app/") else { return nil }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }

    // MARK: Memory text

    public static func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        return "\(Int(mb.rounded())) MB"
    }
}

/// Watches CPU and memory over time and says when a process is running away:
/// busy on a whole core for two minutes, or holding several GB of memory.
public struct RunawayTracker: Sendable {
    public enum Kind: String, Sendable, Equatable { case cpu, memory }

    public static let cpuPercent: Double = 90

    /// How long a process must stay busy, and how much memory is too much.
    public var cpuSeconds: TimeInterval
    public var memoryBytes: UInt64

    /// Since when each process has stayed busy.
    private var busySince: [pid_t: Date] = [:]
    private var memory: [pid_t: UInt64] = [:]

    public init(cpuSeconds: TimeInterval = 120, memoryBytes: UInt64 = 4 * 1024 * 1024 * 1024) {
        self.cpuSeconds = cpuSeconds
        self.memoryBytes = memoryBytes
    }

    public mutating func record(pid: pid_t, cpu: Double, memory bytes: UInt64, at now: Date) {
        if cpu >= Self.cpuPercent {
            if busySince[pid] == nil { busySince[pid] = now }
        } else {
            busySince[pid] = nil
        }
        memory[pid] = bytes
    }

    public func kind(_ pid: pid_t, at now: Date) -> Kind? {
        if let m = memory[pid], m >= memoryBytes { return .memory }
        if let since = busySince[pid], now.timeIntervalSince(since) >= cpuSeconds { return .cpu }
        return nil
    }

    /// Forgets processes that are gone.
    public mutating func keepOnly(_ pids: Set<pid_t>) {
        busySince = busySince.filter { pids.contains($0.key) }
        memory = memory.filter { pids.contains($0.key) }
    }
}

/// "Address already in use": which port a failed command wanted.
public enum PortConflict {
    /// The port from the error text, or from the command line when the error doesn't say
    /// (Python's "[Errno 48] Address already in use"). Nil when nothing says a port was taken.
    public static func port(output: String, command: String) -> Int? {
        let ns = output as NSString
        let all = NSRange(location: 0, length: ns.length)
        guard inUseRE.firstMatch(in: output, range: all) != nil else { return nil }
        for re in portREs {
            if let m = re.firstMatch(in: output, range: all), m.numberOfRanges > 1,
               let p = Int(ns.substring(with: m.range(at: 1))), (1...65535).contains(p) { return p }
        }
        return portInCommand(command)
    }

    /// `-p 8000`, `--port=8000`, `PORT=8000 npm start`, `http.server 8000`, `runserver 0.0.0.0:8000`.
    public static func portInCommand(_ command: String) -> Int? {
        let ns = command as NSString
        for re in commandREs {
            if let m = re.firstMatch(in: command, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1,
               let p = Int(ns.substring(with: m.range(at: 1))), (1...65535).contains(p) { return p }
        }
        return nil
    }

    static let inUseRE = try! NSRegularExpression(
        pattern: #"EADDRINUSE|address already in use|port \d{2,5} (?:is|was) (?:already )?in use|already in use.{0,40}port|errno 48|bind\(\) to .* failed"#,
        options: [.caseInsensitive])
    static let portREs: [NSRegularExpression] = [
        // listen EADDRINUSE: address already in use :::3000 · 127.0.0.1:8080 · tcp :8080: bind
        try! NSRegularExpression(pattern: #"(?:EADDRINUSE|in use|listen tcp)[^\n]{0,40}?:(\d{2,5})\b"#, options: [.caseInsensitive]),
        // Port 3000 is already in use · port 3000 was already in use
        try! NSRegularExpression(pattern: #"\bport\s+(\d{2,5})\s+(?:is|was)\b"#, options: [.caseInsensitive]),
        // Address already in use - bind(2) for "127.0.0.1" port 3000
        try! NSRegularExpression(pattern: #"in use[^\n]{0,60}?\bport\s+(\d{2,5})\b"#, options: [.caseInsensitive]),
        // bind() to 0.0.0.0:80 failed
        try! NSRegularExpression(pattern: #"bind\(\) to [^\s]*:(\d{2,5}) failed"#, options: [.caseInsensitive]),
    ]
    static let commandREs: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:^|\s)(?:-p|--port)(?:=|\s+)(\d{2,5})\b"#),
        try! NSRegularExpression(pattern: #"\bPORT=(\d{2,5})\b"#),
        try! NSRegularExpression(pattern: #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0)?:(\d{2,5})\b"#),
        try! NSRegularExpression(pattern: #"\b(?:http\.server|SimpleHTTPServer|runserver|serve)\s+(\d{2,5})\b"#),
    ]
}
