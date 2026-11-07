import Foundation
import XCTest
@testable import AnserCore

final class ProcessRunnerTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func sh(_ script: String, timeout: TimeInterval = 5) -> ProcessRunner.Result? {
        ProcessRunner.run(["/bin/sh", "-c", script], cwd: NSTemporaryDirectory(), environment: env, timeout: timeout)
    }

    private func isRunning(_ pattern: String) -> Bool {
        let r = ProcessRunner.run(["/usr/bin/pgrep", "-f", pattern], cwd: "/", environment: env, timeout: 5)
        return !(r?.output.isEmpty ?? true)
    }

    func testOutputAndExitStatus() throws {
        let r = try XCTUnwrap(sh("echo hi; echo err >&2; exit 3"))
        XCTAssertEqual(String(decoding: r.output, as: UTF8.self), "hi\nerr\n")
        XCTAssertEqual(r.exitStatus, 3)
        XCTAssertFalse(r.timedOut)
    }

    func testRunsInGivenFolder() throws {
        let r = try XCTUnwrap(ProcessRunner.run(["/bin/pwd"], cwd: "/usr/bin", environment: env, timeout: 5))
        XCTAssertEqual(String(decoding: r.output, as: UTF8.self), "/usr/bin\n")
    }

    /// The old runner killed only `sh`; `sleep` kept the pipe open and the call hung.
    func testTimeoutKillsWholePipeline() throws {
        let start = Date()
        let r = try XCTUnwrap(sh("sleep 31.25 | cat", timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(r.timedOut)
        XCTAssertNil(r.exitStatus)
        XCTAssertFalse(isRunning("sleep 31.25"), "pipeline child should be killed")
    }

    /// A background child that inherits stdout must not keep the call waiting.
    func testBackgroundChildDoesNotBlock() throws {
        defer { _ = ProcessRunner.run(["/usr/bin/pkill", "-f", "sleep 32.5"], cwd: "/", environment: env, timeout: 5) }
        let start = Date()
        let r = try XCTUnwrap(sh("(sleep 32.5 &); echo done", timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(String(decoding: r.output, as: UTF8.self), "done\n")
    }

    func testHugeOutputIsCapped() throws {
        let start = Date()
        let r = try XCTUnwrap(sh("yes", timeout: 10))
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(r.output.count, ProcessRunner.maxOutput)
        XCTAssertFalse(r.timedOut)
    }

    func testDoesNotLeakOpenFiles() throws {
        let tmp = open("/dev/null", O_RDONLY)
        let fd = dup2(tmp, 57)   // a number nothing else uses
        close(tmp)
        defer { close(fd) }
        XCTAssertEqual(fd, 57)
        let r = try XCTUnwrap(ProcessRunner.run(["/bin/ls", "/dev/fd"], cwd: "/", environment: env, timeout: 5))
        let fds = String(decoding: r.output, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertFalse(fds.contains(String(fd)), "app file descriptors leaked: \(fds)")
    }

    func testMissingProgramReturnsNil() {
        XCTAssertNil(ProcessRunner.run(["/nonexistent/tool"], cwd: "/", environment: env, timeout: 1))
    }
}
