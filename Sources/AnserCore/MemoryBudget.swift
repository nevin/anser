import Foundation
import Darwin

/// How much command output a tab keeps in memory. The newest command keeps
/// the most; older ones shrink to their last part and, past the tab's total,
/// are dropped (their end is still in History's saved output, and the full
/// text stays in the terminal's scrollback).
public struct OutputBudget: Sendable, Equatable {
    public var newest: Int
    public var older: Int
    public var total: Int

    public static let standard = OutputBudget(newest: 1 << 20, older: 64 << 10, total: 12 << 20)
    /// When macOS is short of memory.
    public static let tight = OutputBudget(newest: 256 << 10, older: 16 << 10, total: 1 << 20)

    public init(newest: Int, older: Int, total: Int) { self.newest = newest; self.older = older; self.total = total }

    /// For outputs of these sizes (oldest first, nil = none kept), the size each
    /// may keep: its current size, a smaller tail, or nil to drop it.
    public func plan(_ sizes: [Int?]) -> [Int?] {
        var out = [Int?](repeating: nil, count: sizes.count)
        var used = 0
        for i in sizes.indices.reversed() {
            guard let size = sizes[i] else { continue }
            let cap = i == sizes.count - 1 ? newest : older
            let keep = min(size, cap, max(0, total - used))
            if keep <= 0 { continue }
            out[i] = keep
            used += keep
        }
        return out
    }

    /// The last `bytes` of `text` (UTF-8), cut at a line start when one is near.
    public static func tail(_ text: String, bytes: Int) -> String {
        let u = text.utf8
        guard u.count > bytes else { return text }
        var start = u.index(u.endIndex, offsetBy: -bytes)
        // Don't start halfway through a character or line.
        if let nl = u[start...].prefix(4096).firstIndex(of: 0x0A) { start = u.index(after: nl) }
        while start < u.endIndex, (u[start] & 0xC0) == 0x80 { start = u.index(after: start) }
        return String(text[start...])
    }
}

/// The app's real memory use, and handing freed memory back to macOS.
public enum MemoryUse {
    /// What Activity Monitor shows as Memory (the process's physical footprint), in bytes.
    public static func footprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint)
    }

    /// Returns memory the app freed but still holds to macOS. Returns bytes released.
    @discardableResult
    public static func releaseFreed() -> Int { malloc_zone_pressure_relief(nil, 0) }

    public static func megabytes(_ b: UInt64) -> String { String(format: "%.0f MB", Double(b) / 1_048_576) }
}
