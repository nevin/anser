import Foundation

/// Docker containers and Kubernetes pods for the sidebar.
public enum Containers {
    public struct Container: Sendable, Equatable {
        public var id: String
        public var name: String
        public var image: String
        /// "Up 3 minutes", "Exited (0) 2 hours ago".
        public var status: String
        /// "running", "exited", "paused", "restarting"…
        public var state: String
        public var ports: String
        public init(id: String, name: String, image: String, status: String, state: String, ports: String) {
            self.id = id; self.name = name; self.image = image; self.status = status; self.state = state; self.ports = ports
        }
        public var isRunning: Bool { state == "running" || (state.isEmpty && status.hasPrefix("Up")) }

        /// First published port on this Mac ("0.0.0.0:8080->80/tcp" → 8080).
        public var hostPort: Int? {
            let r = try! NSRegularExpression(pattern: #"(?:[\d.]+|\[::\]|::):(\d+)->"#)
            let ns = ports as NSString
            guard let m = r.firstMatch(in: ports, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return Int(ns.substring(with: m.range(at: 1)))
        }
    }

    /// The command that lists containers, one JSON object per line.
    public static let dockerListCommand = ["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"]

    /// Running containers first, then the most recent stopped ones (at most `stopped`).
    public static func parseDocker(_ output: String, stopped: Int = 5) -> [Container] {
        var running: [Container] = [], other: [Container] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            func s(_ k: String) -> String { (obj[k] as? String) ?? "" }
            let name = s("Names").split(separator: ",").first.map(String.init) ?? s("Names")
            guard !name.isEmpty else { continue }
            let c = Container(id: String(s("ID").prefix(12)), name: name, image: s("Image"), status: s("Status"), state: s("State").lowercased(), ports: s("Ports"))
            if c.isRunning { running.append(c) } else { other.append(c) }
        }
        return running + other.prefix(stopped)
    }

    public struct Pod: Sendable, Equatable {
        public var name: String
        public var namespace: String
        public var phase: String
        public var ready: Int
        public var total: Int
        public var restarts: Int
        /// Why a container isn't running ("CrashLoopBackOff", "ImagePullBackOff").
        public var reason: String?
        public var containers: [String]

        public var isHealthy: Bool { phase == "Succeeded" || (phase == "Running" && ready == total && reason == nil) }
        public var statusText: String {
            var s = reason ?? phase
            if total > 0, phase == "Running", reason == nil { s += " \(ready)/\(total)" }
            if restarts > 0 { s += " · \(restarts) restart\(restarts == 1 ? "" : "s")" }
            return s
        }
    }

    /// Pods from `kubectl get pods -o json`.
    public static func parsePods(_ json: String) -> [Pod]? {
        guard let start = json.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            let meta = item["metadata"] as? [String: Any] ?? [:]
            let status = item["status"] as? [String: Any] ?? [:]
            let spec = item["spec"] as? [String: Any] ?? [:]
            guard let name = meta["name"] as? String else { return nil }
            let cs = status["containerStatuses"] as? [[String: Any]] ?? []
            var reason: String?
            for c in cs {
                if let w = (c["state"] as? [String: Any])?["waiting"] as? [String: Any], let r = w["reason"] as? String { reason = r; break }
                if let t = (c["state"] as? [String: Any])?["terminated"] as? [String: Any], let r = t["reason"] as? String, r != "Completed" { reason = r; break }
            }
            if meta["deletionTimestamp"] != nil { reason = "Terminating" }
            let names = (spec["containers"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return Pod(name: name, namespace: meta["namespace"] as? String ?? "default", phase: status["phase"] as? String ?? "Unknown",
                       ready: cs.filter { $0["ready"] as? Bool == true }.count, total: max(cs.count, names.count),
                       restarts: cs.reduce(0) { $0 + (($1["restartCount"] as? Int) ?? 0) }, reason: reason, containers: names)
        }.sorted { ($0.isHealthy ? 1 : 0, $0.name) < ($1.isHealthy ? 1 : 0, $1.name) }
    }

    // MARK: Commands (run in a tab, so you see what happens)

    public static func logs(_ c: Container) -> String { "docker logs -f --tail 200 " + ShellLexer.escape(c.name) }
    public static func shell(_ c: Container) -> String {
        "docker exec -it \(ShellLexer.escape(c.name)) sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }
    public static func logs(_ p: Pod) -> String {
        "kubectl logs -f --tail=200 -n \(ShellLexer.escape(p.namespace)) \(ShellLexer.escape(p.name))" + (p.containers.count > 1 ? " --all-containers" : "")
    }
    public static func shell(_ p: Pod) -> String {
        "kubectl exec -it -n \(ShellLexer.escape(p.namespace)) \(ShellLexer.escape(p.name)) -- sh -c 'command -v bash >/dev/null && exec bash || exec sh'"
    }
    public static func describe(_ p: Pod) -> String { "kubectl describe pod -n \(ShellLexer.escape(p.namespace)) \(ShellLexer.escape(p.name))" }
}

/// An ssh port forward kept open in the background: localhost:localPort → remoteHost:remotePort, through `host`.
public struct SSHTunnel: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// An ssh host (alias from ~/.ssh/config, or user@host).
    public var host: String
    public var localPort: Int
    public var remoteHost: String
    public var remotePort: Int
    /// Open it when Anser starts.
    public var autoStart: Bool?
    /// Extra ssh options (port, key, jump host) when it isn't a ~/.ssh/config alias.
    public var options: [String]?

    public var id: String { "\(host):\(localPort)" }

    public init(name: String, host: String, localPort: Int, remoteHost: String = "localhost", remotePort: Int, autoStart: Bool? = nil, options: [String]? = nil) {
        self.name = name; self.host = host; self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort; self.autoStart = autoStart
        self.options = options
    }

    /// Why this tunnel can't be used, or nil when it's fine.
    public var problem: String? {
        if host.isEmpty { return "Enter an ssh host." }
        if host.hasPrefix("-") || host.contains(where: { $0.isWhitespace }) { return "The ssh host can't start with “-” or contain spaces." }
        if remoteHost.isEmpty || remoteHost.hasPrefix("-") || remoteHost.contains(where: { $0.isWhitespace || $0 == ":" }) && !remoteHost.hasPrefix("[") {
            return "Enter the host to reach from the server (often localhost)."
        }
        if !(1...65535).contains(localPort) || !(1...65535).contains(remotePort) { return "Ports go from 1 to 65535." }
        return nil
    }

    /// "db on :5433 → localhost:5432 via bastion".
    public var summary: String { ":\(localPort) → \(remoteHost):\(remotePort) via \(host)" }

    /// The ssh command. BatchMode: it runs without a terminal, so it can't ask for a password.
    public func argv(ssh: String = "/usr/bin/ssh", interactive: Bool = false) -> [String] {
        var a = [ssh, "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if !interactive { a += ["-o", "BatchMode=yes"] }
        a += (options ?? []).filter { !$0.isEmpty }
        a += ["-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)", "--", host]
        return a
    }
}

/// Copying files to and from the server an ssh tab is connected to.
public enum SSHCopy {
    /// scp options taken from the ssh command that opened the session (port, key, jump host…) and its target.
    public static func options(fromSSH command: String) -> (options: [String], target: String)? {
        guard let host = SSHConfig.target(of: command) else { return nil }
        let words = ShellLexer.tokenize(command).filter { $0.kind == .word }.map(\.value)
        var opts: [String] = []
        var user: String?
        var i = 1
        while i < words.count {
            let w = words[i]
            if w == "--" { break }
            if w.hasPrefix("-"), w.count >= 2 {
                let flag = String(w.prefix(2))
                let inline = w.count > 2 ? String(w.dropFirst(2)) : nil
                let takes = Set(["-p", "-i", "-J", "-o", "-F", "-l", "-c", "-b", "-D", "-L", "-R", "-W", "-w", "-E", "-e", "-I", "-m", "-O", "-Q", "-S", "-B"])
                if takes.contains(flag) {
                    let value = inline ?? (i + 1 < words.count ? words[i + 1] : "")
                    if inline == nil { i += 1 }
                    switch flag {
                    case "-p": opts += ["-P", value]
                    case "-i", "-J", "-o", "-F", "-c": opts += [flag, value]
                    case "-l": user = value
                    default: break
                    }
                } else {
                    for ch in w.dropFirst() where "46C".contains(ch) { opts.append("-\(ch)") }
                }
                i += 1
                continue
            }
            break
        }
        let target = (user != nil && !host.contains("@")) ? "\(user!)@\(host)" : host
        guard !target.hasPrefix("-") else { return nil }
        return (opts, target)
    }

    /// A remote path for scp: relative paths are inside `remoteCwd`.
    public static func remotePath(_ path: String, remoteCwd: String?) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") { return path }
        let base = remoteCwd ?? "~"
        return base.hasSuffix("/") ? base + path : base + "/" + path
    }

    public static func uploadArgv(files: [String], to remoteDir: String, options: [String], target: String, batch: Bool = true) -> [String] {
        ["/usr/bin/scp"] + options + (batch ? ["-o", "BatchMode=yes"] : []) + ["-r", "-p", "--"] + files + ["\(target):\(remoteDir.hasSuffix("/") ? remoteDir : remoteDir + "/")"]
    }

    public static func downloadArgv(remote: String, to localDir: String, options: [String], target: String, batch: Bool = true) -> [String] {
        ["/usr/bin/scp"] + options + (batch ? ["-o", "BatchMode=yes"] : []) + ["-r", "-p", "--", "\(target):\(remote)", localDir]
    }
}

/// Commands worth a second look before running (for AI-proposed steps).
public enum CommandRisk {
    /// A short reason when `command` deletes, overwrites or force-changes something.
    public static func reason(_ command: String) -> String? {
        let c = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let checks: [(String, String)] = [
            (#"\brm\s+(-[a-z]*r[a-z]*|-[a-z]*f[a-z]*r|--recursive)"#, "deletes files and folders"),
            (#"\bsudo\b"#, "runs as administrator"),
            (#"\bgit\s+push\b.*(\s-f\b|--force)"#, "force-pushes, which can overwrite others' work"),
            (#"\bgit\s+reset\s+--hard"#, "throws away uncommitted changes"),
            (#"\bgit\s+clean\s+-[a-z]*f"#, "deletes untracked files"),
            (#"\bgit\s+(checkout|restore)\s+(--\s+)?\.\s"#, "throws away uncommitted changes"),
            (#"\bgit\s+branch\s+-D\b"#, "deletes a branch"),
            (#"\bkubectl\s+(delete|drain|scale)\b"#, "changes the cluster"),
            (#"\bhelm\s+(uninstall|delete|rollback)\b"#, "changes the cluster"),
            (#"\bterraform\s+(apply|destroy)\b"#, "changes infrastructure"),
            (#"\bdocker\s+(rm|rmi|system\s+prune|volume\s+(rm|prune))\b"#, "deletes Docker data"),
            (#"\bdrop\s+(table|database|schema)\b"#, "deletes data"),
            (#"\btruncate\s+table\b"#, "deletes data"),
            (#"\b(mkfs|dd\s+if=|diskutil\s+erase)"#, "can erase a disk"),
            (#"\bchmod\s+-r|\bchown\s+-r"#, "changes permissions on many files"),
            (#"(curl|wget)[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "runs a script from the internet"),
            (#">\s*/dev/(disk|sd)"#, "writes to a disk directly"),
            (#"\bkill(all)?\s+-9\b"#, "force-stops processes"),
            (#"\bnpm\s+publish\b|\bcargo\s+publish\b|\bgem\s+push\b"#, "publishes a package"),
        ]
        for (pattern, why) in checks where c.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil { return why }
        return nil
    }
}
