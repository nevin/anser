import XCTest
@testable import AnserCore

final class ProcessScanTests: XCTestCase {
    func testTreesListChildrenUnderTheirShell() {
        let t0 = Date(timeIntervalSince1970: 100)
        let procs = [
            ProcessScan.Proc(pid: 10, ppid: 1, name: "zsh"),
            ProcessScan.Proc(pid: 20, ppid: 10, name: "npm", started: t0),
            ProcessScan.Proc(pid: 21, ppid: 20, name: "node", started: t0.addingTimeInterval(1)),
            ProcessScan.Proc(pid: 22, ppid: 21, name: "esbuild", started: t0.addingTimeInterval(2)),
            ProcessScan.Proc(pid: 30, ppid: 10, name: "sleep", started: t0.addingTimeInterval(5)),
            ProcessScan.Proc(pid: 40, ppid: 1, name: "other"),
        ]
        let trees = ProcessScan.trees(under: [10, 99], in: procs)
        XCTAssertEqual(trees[10]?.map(\.proc.name), ["npm", "node", "esbuild", "sleep"])
        XCTAssertEqual(trees[10]?.map(\.depth), [1, 2, 3, 1])
        XCTAssertNil(trees[99])
    }

    func testJobsLeaveOutShellHelpers() {
        let shell = ProcessScan.Proc(pid: 10, ppid: 1, pgid: 10, name: "zsh", tty: 7)
        let nodes = [
            ProcessScan.Node(proc: .init(pid: 11, ppid: 10, pgid: 10, name: "git", tty: 7), depth: 1),       // $(git …) in the prompt
            ProcessScan.Node(proc: .init(pid: 12, ppid: 10, pgid: 12, name: "zsh", tty: 9), depth: 1),       // async worker on its own pty
            ProcessScan.Node(proc: .init(pid: 13, ppid: 12, pgid: 12, name: "git", tty: 9), depth: 2),
            ProcessScan.Node(proc: .init(pid: 14, ppid: 10, pgid: 14, name: "npm", tty: 7), depth: 1),       // a command
            ProcessScan.Node(proc: .init(pid: 15, ppid: 14, pgid: 14, name: "node", tty: 7), depth: 2),
        ]
        XCTAssertEqual(ProcessScan.jobs(of: shell, nodes).map(\.proc.pid), [14, 15])
        // Just started: wait for the next look (prompt helpers come and go).
        let fresh = [ProcessScan.Node(proc: .init(pid: 16, ppid: 10, pgid: 16, name: "zsh", started: Date(), tty: 7), depth: 1),
                     ProcessScan.Node(proc: .init(pid: 17, ppid: 10, pgid: 17, name: "gitstatusd-darwin-arm64", tty: 7), depth: 1)]
        XCTAssertTrue(ProcessScan.jobs(of: shell, fresh).isEmpty)
    }

    func testParsesProcArgs() {
        var bytes: [UInt8] = []
        var argc: Int32 = 2
        withUnsafeBytes(of: &argc) { bytes += $0 }
        for s in ["/usr/bin/node", "", "", "node", "server.js", "ANSER_FIFO=/tmp/f", "HOME=/Users/x", ""] { bytes += Array(s.utf8) + [0] }
        let a = ProcessScan.parseProcArgs(bytes)
        XCTAssertEqual(a?.executable, "/usr/bin/node")
        XCTAssertEqual(a?.commandLine, "node server.js")
        XCTAssertEqual(a?.env["ANSER_FIFO"], "/tmp/f")
        XCTAssertEqual(a?.env["HOME"], "/Users/x")
        XCTAssertNil(ProcessScan.parseProcArgs([1, 0]))
    }

    func testReadsThisProcess() {
        let me = getpid()
        XCTAssertTrue(ProcessScan.all().contains { $0.pid == me })
        XCTAssertNotNil(ProcessScan.usage(me))
        XCTAssertGreaterThan(ProcessScan.usage(me)?.memory ?? 0, 0)
        XCTAssertNotNil(ProcessScan.arguments(me))
    }

    func testSystemAndAppNames() {
        XCTAssertTrue(ProcessScan.isSystem(path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        XCTAssertTrue(ProcessScan.isSystem(path: "/usr/libexec/rapportd"))
        XCTAssertTrue(ProcessScan.isSystem(path: nil))
        XCTAssertFalse(ProcessScan.isSystem(path: "/opt/homebrew/bin/node"))
        XCTAssertEqual(ProcessScan.appName(path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"), "Docker")
        XCTAssertNil(ProcessScan.appName(path: "/usr/local/bin/redis-server"))
    }

    func testCPUAndMemoryText() {
        let a = ProcessScan.Usage(cpuNanos: 0, memory: 0), b = ProcessScan.Usage(cpuNanos: 1_500_000_000, memory: 0)
        XCTAssertEqual(ProcessScan.cpuPercent(from: a, to: b, seconds: 1), 150, accuracy: 0.01)
        XCTAssertEqual(ProcessScan.cpuPercent(from: b, to: a, seconds: 1), 0)
        XCTAssertEqual(ProcessScan.formatMemory(340 * 1_048_576), "340 MB")
        XCTAssertEqual(ProcessScan.formatMemory(4_509_715_660), "4.2 GB")
    }

    func testRunawayNeedsToStayBusy() {
        var t = RunawayTracker(cpuSeconds: 120)
        let t0 = Date()
        t.record(pid: 5, cpu: 99, memory: 1, at: t0)
        XCTAssertNil(t.kind(5, at: t0.addingTimeInterval(60)))
        t.record(pid: 5, cpu: 99, memory: 1, at: t0.addingTimeInterval(60))
        XCTAssertEqual(t.kind(5, at: t0.addingTimeInterval(121)), .cpu)
        // A quiet moment starts the clock again.
        t.record(pid: 5, cpu: 3, memory: 1, at: t0.addingTimeInterval(122))
        XCTAssertNil(t.kind(5, at: t0.addingTimeInterval(130)))
        t.record(pid: 6, cpu: 0, memory: 5 * 1024 * 1024 * 1024, at: t0)
        XCTAssertEqual(t.kind(6, at: t0), .memory)
        t.keepOnly([5])
        XCTAssertNil(t.kind(6, at: t0))
    }

    func testPortConflicts() {
        XCTAssertEqual(PortConflict.port(output: "Error: listen EADDRINUSE: address already in use :::3000", command: "npm run dev"), 3000)
        XCTAssertEqual(PortConflict.port(output: "listen tcp :8080: bind: address already in use", command: "go run ."), 8080)
        XCTAssertEqual(PortConflict.port(output: "Address already in use - bind(2) for \"127.0.0.1\" port 3001 (Errno::EADDRINUSE)", command: "rails s"), 3001)
        XCTAssertEqual(PortConflict.port(output: "Web server failed to start. Port 8081 was already in use.", command: "./gradlew bootRun"), 8081)
        XCTAssertEqual(PortConflict.port(output: "⚠ Port 3002 is already in use", command: "next dev"), 3002)
        XCTAssertEqual(PortConflict.port(output: "OSError: [Errno 48] Address already in use", command: "python3 -m http.server 8000 --bind 127.0.0.1"), 8000)
        XCTAssertEqual(PortConflict.port(output: "OSError: [Errno 48] Address already in use", command: "PORT=5001 flask run"), 5001)
        XCTAssertEqual(PortConflict.port(output: "nginx: [emerg] bind() to 0.0.0.0:8088 failed (48: Address already in use)", command: "nginx"), 8088)
        XCTAssertNil(PortConflict.port(output: "Error: something else entirely on port 3000", command: "npm start"))
        XCTAssertNil(PortConflict.port(output: "OSError: [Errno 48] Address already in use", command: "python3 app.py"))
    }
}
