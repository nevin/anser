import XCTest
import Darwin
@testable import AnserCore

/// Handing a shell's terminal from the session helper to a tab, over the socket.
final class DescriptorPassingTests: XCTestCase {
    func testTerminalPassedOverSocketWorksAtTheOtherEnd() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master); close(slave) }

        let header = SessionProtocol.frame(.handoff, Data())
        XCTAssertEqual(DescriptorPassing.send(pair[0], header, passing: master), header.count)

        var buf = [UInt8](repeating: 0, count: 64)
        var received: Int32?
        let n = buf.withUnsafeMutableBytes { DescriptorPassing.receive(pair[1], $0.baseAddress!, $0.count, &received) }
        XCTAssertEqual(n, header.count)
        var decoder = SessionProtocol.Decoder()
        let frames = decoder.append(Data(buf[0..<n]))
        XCTAssertEqual(frames.first?.0, .handoff)
        let fd = try XCTUnwrap(received)
        defer { close(fd) }
        XCTAssertNotEqual(fd, master)
        XCTAssertEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, FD_CLOEXEC)

        // Same terminal: what the program writes shows up on the passed copy, and back.
        XCTAssertEqual(write(slave, "out\n", 4), 4)
        var r = [UInt8](repeating: 0, count: 64)
        let got = read(fd, &r, r.count)
        XCTAssertTrue(String(decoding: r[0..<max(got, 0)], as: UTF8.self).contains("out"))
        // Size set through the passed copy is the terminal's size.
        var ws = winsize(ws_row: 33, ws_col: 101, ws_xpixel: 0, ws_ypixel: 0)
        XCTAssertEqual(ioctl(fd, TIOCSWINSZ, &ws), 0)
        var seen = winsize()
        XCTAssertEqual(ioctl(slave, TIOCGWINSZ, &seen), 0)
        XCTAssertEqual(seen.ws_col, 101)
        XCTAssertEqual(seen.ws_row, 33)
    }

    func testPlainBytesCarryNoDescriptor() {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { pair.forEach { close($0) } }
        XCTAssertEqual(write(pair[0], "hello", 5), 5)
        var buf = [UInt8](repeating: 0, count: 16)
        var received: Int32?
        let n = buf.withUnsafeMutableBytes { DescriptorPassing.receive(pair[1], $0.baseAddress!, $0.count, &received) }
        XCTAssertEqual(n, 5)
        XCTAssertNil(received)
    }
}
