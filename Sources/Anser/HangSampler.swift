import Darwin
import Foundation

/// Reads the main thread's call stack from the hang watchdog, so a logged hang
/// says what the app was doing. The main thread is paused only for the few
/// microseconds it takes to copy its frame chain; nothing is allocated while
/// it's paused (it might be holding the allocator's lock).
enum HangSampler {
    private static var mainThread: thread_act_t = 0
    private static let capacity = 48
    private static let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)

    /// Call once on the main thread.
    static func recordMainThread() {
        if mainThread == 0 { mainThread = mach_thread_self() }
    }

    /// Return addresses on the main thread right now, innermost first.
    static func sample() -> [UInt] {
        #if arch(arm64)
        let t = mainThread
        guard t != 0, thread_suspend(t) == KERN_SUCCESS else { return [] }
        var n = 0
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(t, ARM_THREAD_STATE64, $0, &count) }
        }
        if kr == KERN_SUCCESS {
            buffer[0] = strip(UInt(state.__pc)); n = 1
            buffer[1] = strip(UInt(state.__lr)); n = 2
            var fp = UInt(state.__fp)
            var pair: (UInt, UInt) = (0, 0)
            while n < capacity, fp != 0, fp & 7 == 0 {
                var got: vm_size_t = 0
                let r = withUnsafeMutablePointer(to: &pair) {
                    vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &got)
                }
                guard r == KERN_SUCCESS, got == 16 else { break }
                let ret = strip(pair.1)
                guard ret != 0 else { break }
                buffer[n] = ret; n += 1
                guard pair.0 > fp else { break }
                fp = pair.0
            }
        }
        thread_resume(t)
        var out: [UInt] = []
        for i in 0..<n where out.last != buffer[i] { out.append(buffer[i]) }
        return out
        #else
        return []
        #endif
    }

    /// One line per frame: "Image  symbol + offset".
    static func describe(_ frames: [UInt], limit: Int = 28) -> [String] {
        frames.prefix(limit).map { addr in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { return String(format: "?  0x%llx", UInt64(addr)) }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            if let s = info.dli_sname {
                let name = demangle(String(cString: s))
                let off = addr &- UInt(bitPattern: info.dli_saddr)
                return "\(image)  \(name) + \(off)"
            }
            return String(format: "%@ + 0x%llx", image, UInt64(addr &- UInt(bitPattern: info.dli_fbase)))
        }
    }

    // Pointer-authentication bits on return addresses saved by system code.
    private static func strip(_ a: UInt) -> UInt { a & 0x0000_7FFF_FFFF_FFFF }

    private static func demangle(_ s: String) -> String {
        var name = s.hasPrefix("_$s") || s.hasPrefix("_T") ? String(s.dropFirst()) : s
        guard name.hasPrefix("$s") else { return s }
        name.withCString { c in
            if let out = anser_swift_demangle(c, strlen(c), nil, nil, 0) {
                name = String(cString: out)
                free(out)
            }
        }
        return name.count > 160 ? String(name.prefix(160)) + "…" : name
    }
}

@_silgen_name("swift_demangle")
private func anser_swift_demangle(_ mangled: UnsafePointer<CChar>, _ length: Int, _ out: UnsafeMutablePointer<CChar>?, _ outLength: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
