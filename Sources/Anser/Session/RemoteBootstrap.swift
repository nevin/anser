import Foundation

/// Builds the one-line command `ssh -t host <command>` runs on the remote host:
/// it unpacks Anser's remote hooks into a private temp folder for that session.
enum RemoteBootstrap {
    /// Path of a file holding the command (handed to the local shell's ssh wrapper).
    static let path: String? = {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("shell/remote"),
              let zsh = try? Data(contentsOf: dir.appendingPathComponent("anser-remote.zsh")),
              let bash = try? Data(contentsOf: dir.appendingPathComponent("anser-remote.bash")),
              let script = try? String(contentsOf: dir.appendingPathComponent("bootstrap.sh"), encoding: .utf8) else { return nil }
        let filled = script
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            .replacingOccurrences(of: "@@ZSH@@", with: zsh.base64EncodedString())
            .replacingOccurrences(of: "@@BASH@@", with: bash.base64EncodedString())
        // Run through sh whatever the remote login shell is.
        let command = "exec sh -c '" + filled.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let out = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Anser")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = out.appendingPathComponent("ssh-bootstrap.txt")
        do { try command.write(to: file, atomically: true, encoding: .utf8) } catch { return nil }
        return file.path
    }()
}
