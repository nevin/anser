import Foundation

/// Which Kubernetes cluster, AWS profile, Docker context and Google Cloud
/// project commands would talk to right now — so "oops, that was prod"
/// doesn't happen. Read from the same files and variables the tools use.
public struct CloudContext: Sendable, Equatable {
    public var kube: String?
    public var namespace: String?
    public var aws: String?
    public var docker: String?
    public var gcloud: String?

    public init(kube: String? = nil, namespace: String? = nil, aws: String? = nil, docker: String? = nil, gcloud: String? = nil) {
        self.kube = kube; self.namespace = namespace; self.aws = aws; self.docker = docker; self.gcloud = gcloud
    }

    public var isEmpty: Bool { kube == nil && aws == nil && docker == nil && gcloud == nil }

    /// Variables from the shell that change the context.
    public struct Vars: Sendable, Equatable {
        public var awsProfile: String?
        public var kubeconfig: String?
        public var dockerContext: String?
        public var gcloudProject: String?
        /// The active Python virtualenv (for project environments, not the cloud chip).
        public var virtualEnv: String?
        public init(awsProfile: String? = nil, kubeconfig: String? = nil, dockerContext: String? = nil, gcloudProject: String? = nil, virtualEnv: String? = nil) {
            self.awsProfile = awsProfile; self.kubeconfig = kubeconfig; self.dockerContext = dockerContext; self.gcloudProject = gcloudProject
            self.virtualEnv = virtualEnv
        }
    }

    /// Reads the current context. `home` and `read` are swappable for tests.
    public static func current(vars: Vars, home: String = NSHomeDirectory(),
                               read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> CloudContext {
        var c = CloudContext()
        // Kubernetes: the first kubeconfig file that sets current-context.
        let files = (vars.kubeconfig?.isEmpty == false ? vars.kubeconfig!.split(separator: ":").map(String.init) : [home + "/.kube/config"])
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        let texts = files.compactMap(read)
        for t in texts {
            if let cur = Self.kubeCurrent(t) { c.kube = cur; break }
        }
        if let k = c.kube {
            for t in texts { if let ns = Self.kubeNamespaces(t)[k] { c.namespace = ns; break } }
        }
        c.aws = vars.awsProfile.flatMap { $0.isEmpty ? nil : $0 }
        if let d = vars.dockerContext, !d.isEmpty {
            c.docker = d
        } else if let json = read(home + "/.docker/config.json"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let d = obj["currentContext"] as? String, !d.isEmpty {
            c.docker = d
        }
        if c.docker == "default" || c.docker == "desktop-linux" { c.docker = nil }
        if let p = vars.gcloudProject, !p.isEmpty {
            c.gcloud = p
        } else if let active = read(home + "/.config/gcloud/active_config")?.trimmingCharacters(in: .whitespacesAndNewlines), !active.isEmpty,
                  let cfg = read(home + "/.config/gcloud/configurations/config_\(active)") {
            c.gcloud = Self.iniValue(cfg, key: "project")
        }
        return c
    }

    static func kubeCurrent(_ yaml: String) -> String? {
        for line in yaml.split(separator: "\n") where line.hasPrefix("current-context:") {
            let v = Self.unquote(line.dropFirst("current-context:".count))
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Context name → namespace, from the `contexts:` list.
    static func kubeNamespaces(_ yaml: String) -> [String: String] {
        var out: [String: String] = [:]
        var inContexts = false
        var name: String?, ns: String?
        func flush() { if let n = name, let s = ns { out[n] = s }; name = nil; ns = nil }
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.isEmpty {
                flush()
                inContexts = line.hasPrefix("contexts:")
                continue
            }
            guard inContexts else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { flush() }
            let body = t.hasPrefix("- ") ? String(t.dropFirst(2)) : t
            // `name:` of the item (two spaces in) vs the context's own fields.
            if body.hasPrefix("name:") { name = Self.unquote(body.dropFirst(5)) }
            if body.hasPrefix("namespace:") { ns = Self.unquote(body.dropFirst(10)) }
        }
        flush()
        return out
    }

    /// Every context name in the kubeconfig files, for switching.
    public static func kubeContextNames(vars: Vars, home: String = NSHomeDirectory(),
                                        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String] {
        let files = (vars.kubeconfig?.isEmpty == false ? vars.kubeconfig!.split(separator: ":").map(String.init) : [home + "/.kube/config"])
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        var out: [String] = []
        for t in files.compactMap(read) {
            var inContexts = false
            for raw in t.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if !line.hasPrefix(" ") && !line.hasPrefix("-") && !line.isEmpty { inContexts = line.hasPrefix("contexts:"); continue }
                guard inContexts else { continue }
                var body = line.trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("- ") { body = String(body.dropFirst(2)) }
                // The item's own name sits two spaces in (or right after "- "); a context's cluster/user fields are deeper.
                let indent = line.prefix(while: { $0 == " " || $0 == "-" }).count
                if body.hasPrefix("name:"), indent <= 2 {
                    let n = unquote(body.dropFirst(5))
                    if !n.isEmpty, !out.contains(n) { out.append(n) }
                }
            }
        }
        return out
    }

    /// AWS profile names from ~/.aws/config and ~/.aws/credentials.
    public static func awsProfiles(home: String = NSHomeDirectory(),
                                   read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> [String] {
        var out: [String] = []
        for f in [home + "/.aws/config", home + "/.aws/credentials"] {
            for line in (read(f) ?? "").split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("["), t.hasSuffix("]") else { continue }
                var n = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if n.hasPrefix("profile ") { n = String(n.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
                if n.hasPrefix("sso-session ") || n.hasPrefix("services ") { continue }
                if !n.isEmpty, !out.contains(n) { out.append(n) }
            }
        }
        return out
    }

    static func iniValue(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2, p[0] == key, !p[1].isEmpty { return p[1] }
        }
        return nil
    }

    static func unquote<S: StringProtocol>(_ s: S) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// Whether a command talks to one of these services, so the chip is worth showing.
    public static func tools(in command: String) -> Set<String> {
        var out = Set<String>()
        let words = ShellLexer.tokenize(command).filter { $0.kind == .word }.map { ($0.value as NSString).lastPathComponent }
        for w in words {
            switch w {
            case "kubectl", "k", "helm", "k9s", "kubectx", "kubens", "kustomize", "skaffold", "tilt", "stern", "argocd", "flux": out.insert("kube")
            case "aws", "sam", "cdk", "eksctl", "copilot", "terraform", "tofu", "pulumi", "serverless", "sls": out.insert("aws")
            case "docker", "docker-compose", "compose": out.insert("docker")
            case "gcloud", "gsutil", "bq": out.insert("gcloud")
            default: break
            }
        }
        return out
    }

    /// Short chip text for the parts in `show` ("⎈ prod/payments · aws:admin").
    public func summary(showing show: Set<String>) -> String {
        var parts: [String] = []
        if show.contains("kube"), let k = kube { parts.append(namespace.map { "\(k)/\($0)" } ?? k) }
        if show.contains("aws"), let a = aws { parts.append("aws:\(a)") }
        if show.contains("gcloud"), let g = gcloud { parts.append("gcp:\(g)") }
        if show.contains("docker"), let d = docker { parts.append("docker:\(d)") }
        return parts.joined(separator: " · ")
    }
}
