import Foundation
import Darwin

/// Passing an open file (a shell's terminal) over a Unix socket, so its new holder reads and
/// writes it directly. Both ends keep a working copy; each closes its own.
public enum DescriptorPassing {
    /// One cmsghdr carrying one descriptor: 12-byte header + 4-byte fd on Darwin.
    static let controlSize = 16

    /// Sends `bytes` (at least one) with `fd` attached, like write(2): the count sent, or -1.
    /// The descriptor goes with the first byte, so a short write still delivers it.
    public static func send(_ sock: Int32, _ bytes: Data, passing fd: Int32) -> Int {
        precondition(!bytes.isEmpty, "a descriptor needs at least one byte to ride on")
        var control = [UInt8](repeating: 0, count: controlSize)
        control.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(controlSize), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: SOL_SOCKET, toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: SCM_RIGHTS, toByteOffset: 8, as: Int32.self)
            raw.storeBytes(of: fd, toByteOffset: 12, as: Int32.self)
        }
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { b in
            control.withUnsafeMutableBytes { c in
                var iov = iovec(iov_base: b.baseAddress, iov_len: b.count)
                return withUnsafeMutablePointer(to: &iov) { iovp in
                    var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                     msg_control: c.baseAddress, msg_controllen: socklen_t(controlSize), msg_flags: 0)
                    return sendmsg(sock, &msg, 0)
                }
            }
        }
    }

    /// Reads like read(2). A descriptor that came with these bytes is stored in `received`,
    /// close-on-exec. Extra descriptors (never sent by Anser) are closed.
    public static func receive(_ sock: Int32, _ buf: UnsafeMutableRawPointer, _ capacity: Int,
                               _ received: inout Int32?) -> Int {
        var control = [UInt8](repeating: 0, count: 64)
        var iov = iovec(iov_base: buf, iov_len: capacity)
        var fds: [Int32] = []
        let n: Int = control.withUnsafeMutableBytes { c in
            withUnsafeMutablePointer(to: &iov) { iovp in
                var msg = msghdr(msg_name: nil, msg_namelen: 0, msg_iov: iovp, msg_iovlen: 1,
                                 msg_control: c.baseAddress, msg_controllen: socklen_t(c.count), msg_flags: 0)
                let n = recvmsg(sock, &msg, 0)
                guard n >= 0 else { return n }
                // Walk the control messages (4-byte aligned on Darwin).
                var off = 0
                let total = Int(msg.msg_controllen)
                while off + 12 <= total {
                    let len = Int(c.load(fromByteOffset: off, as: UInt32.self))
                    guard len >= 12, off + len <= total else { break }
                    if c.load(fromByteOffset: off + 4, as: Int32.self) == SOL_SOCKET,
                       c.load(fromByteOffset: off + 8, as: Int32.self) == SCM_RIGHTS {
                        var at = off + 12
                        while at + 4 <= off + len { fds.append(c.load(fromByteOffset: at, as: Int32.self)); at += 4 }
                    }
                    off += (len + 3) & ~3
                }
                return n
            }
        }
        for (i, fd) in fds.enumerated() {
            if i == 0 && received == nil {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                received = fd
            } else {
                close(fd)
            }
        }
        return n
    }
}
