import Darwin

extension ServerPorts {
    /// Servers running under each of `shells` (shell pid → its listeners), read
    /// straight from the kernel. Only the shells' own descendants are looked at,
    /// so this costs a few system calls instead of running lsof over every process.
    public static func listeners(under shells: [pid_t]) -> [pid_t: [Listener]] {
        let roots = Set(shells.filter { $0 > 1 })
        guard !roots.isEmpty else { return [:] }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in allParents() where pid != ppid { children[ppid, default: []].append(pid) }

        var out: [pid_t: [Listener]] = [:]
        for shell in roots {
            var found: [Listener] = []
            var seen = Set<Int>()
            var queue = children[shell] ?? []
            var visited = Set<pid_t>(queue)
            while let pid = queue.popLast() {
                for port in listeningPorts(pid) where seen.insert(port.port).inserted {
                    found.append(Listener(pid: pid, process: ForegroundJob.name(pid) ?? "process \(pid)", port: port.port, address: port.address))
                }
                for c in children[pid] ?? [] where visited.insert(c).inserted { queue.append(c) }
            }
            if !found.isEmpty { out[shell] = found.sorted { $0.port < $1.port } }
        }
        return out
    }

    /// Every process's parent, in one sysctl call.
    static func allParents() -> [(pid_t, pid_t)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Processes can start between the two calls: leave room.
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard procs.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        return procs.prefix(size / stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
    }

    /// TCP ports `pid` is listening on.
    static func listeningPorts(_ pid: pid_t) -> [(port: Int, address: String)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var out: [(Int, String)] = []
        for fd in fds.prefix(Int(got) / fdSize) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var si = socket_fdinfo()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
            guard n == Int32(MemoryLayout<socket_fdinfo>.size), si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(truncatingIfNeeded: ini.insi_lport).byteSwapped)
            guard port > 0 else { continue }
            out.append((port, address(ini)))
        }
        return out
    }

    private static func address(_ ini: in_sockinfo) -> String {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            var a = ini.insi_laddr.ina_46.i46a_addr4
            if a.s_addr == 0 { return "*" }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            return String(cString: buf)
        }
        var a6 = ini.insi_laddr.ina_6
        if withUnsafeBytes(of: &a6, { $0.allSatisfy { $0 == 0 } }) { return "*" }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        inet_ntop(AF_INET6, &a6, &buf, socklen_t(buf.count))
        return "[\(String(cString: buf))]"
    }
}
