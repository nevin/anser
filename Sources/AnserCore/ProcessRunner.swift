import Foundation

/// Runs a helper command with a hard time limit.
///
/// The command gets its own process group, so on timeout the whole pipeline
/// (`sh`, `git`, `wc`, …) is killed, not just the first process. Output is read
/// until the command exits; children it leaves running in the background are
/// not waited for and not killed.
enum ProcessRunner {
    struct Result {
        var output: Data
        var exitStatus: Int32?   // nil when killed for timeout or too much output
        var timedOut: Bool
    }

    /// Output beyond this is dropped and the command is stopped.
    static let maxOutput = 8 << 20
    /// How long to keep reading after the command exits, for output still in the pipe.
    static let drainAfterExit: TimeInterval = 0.2

    static func run(_ argv: [String], cwd: String, environment: [String: String], timeout: TimeInterval) -> Result? {
        guard let exe = argv.first else { return nil }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
        posix_spawn_file_actions_addchdir_np(&actions, cwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Own process group (pgid = pid), no inherited file descriptors besides 0-2,
        // default signal handling and an empty signal mask.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t(); sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        var allSignals = sigset_t(); sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, &actions, &attr, cArgs, cEnv)
        close(writeFD)
        guard rc == 0 else { close(readFD); return nil }
        defer { close(readFD) }

        var output = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        var status: Int32 = 0
        var eof = false
        var overflow = false

        while true {
            if exitedAt == nil, waitpid(pid, &status, WNOHANG) == pid { exitedAt = Date() }
            if let t = exitedAt, eof || Date() >= t.addingTimeInterval(drainAfterExit) { break }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 || overflow { break }
            if eof {
                // Output closed but the process hasn't exited yet.
                usleep(5_000)
                continue
            }
            var p = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ms = Int32(max(1, min(remaining, 0.05) * 1000))
            guard poll(&p, 1, ms) > 0 else { continue }
            let n = read(readFD, &buf, buf.count)
            if n > 0 {
                output.append(buf, count: n)
                if output.count > maxOutput { output = output.prefix(maxOutput); overflow = true }
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                eof = true
            }
        }

        if exitedAt != nil {
            return Result(output: output, exitStatus: exitCode(status), timedOut: false)
        }
        // Still running: stop the whole group, politely first.
        kill(-pid, SIGTERM)
        let grace = Date().addingTimeInterval(0.2)
        while waitpid(pid, &status, WNOHANG) == 0 && Date() < grace { usleep(5_000) }
        kill(-pid, SIGKILL)
        if waitpid(pid, &status, WNOHANG) == 0 { waitpid(pid, &status, 0) }
        return Result(output: output, exitStatus: nil, timedOut: !overflow)
    }

    private static func exitCode(_ status: Int32) -> Int32? {
        // WIFEXITED / WEXITSTATUS are macros Swift can't import.
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }
}
