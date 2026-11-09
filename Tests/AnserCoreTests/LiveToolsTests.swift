import Foundation
import XCTest
@testable import AnserCore

final class InputWaitTests: XCTestCase {
    func testConfirmAndPassword() {
        XCTAssertEqual(InputWait.detect(screen: "Removing 3 files\nProceed? [y/N] ")?.kind, .confirm)
        XCTAssertEqual(InputWait.detect(screen: "Do you want to continue? [Y/n]")?.kind, .confirm)
        XCTAssertEqual(InputWait.detect(screen: "[sudo] password for sneha: ")?.kind, .password)
        XCTAssertEqual(InputWait.detect(screen: "Enter passphrase for key '/Users/x/.ssh/id_ed25519': ")?.kind, .password)
        XCTAssertEqual(InputWait.detect(screen: "Password:")?.kind, .password)
        XCTAssertEqual(InputWait.detect(screen: "Press any key to continue...")?.kind, .keypress)
    }

    func testAgentApproval() {
        let screen = """
        ╭──────────────────────────────╮
        │ Bash command                 │
        │   rm -rf build               │
        │ Do you want to proceed?      │
        │ ❯ 1. Yes                     │
        │   2. Yes, and don't ask again│
        │   3. No (esc)                │
        ╰──────────────────────────────╯
        """
        let w = InputWait.detect(screen: screen)
        XCTAssertEqual(w?.kind, .agent)
    }

    func testOrdinaryOutputIsNotWaiting() {
        XCTAssertNil(InputWait.detect(screen: "Compiling foo v0.1.0\nBuilding [=====>    ] 120/300"))
        XCTAssertNil(InputWait.detect(screen: "12:01:03 GET /health 200"))
        XCTAssertNil(InputWait.detect(screen: ""))
        XCTAssertNil(InputWait.detect(screen: "http://localhost:3000/?"))
        XCTAssertEqual(InputWait.detect(screen: "What is your project name?")?.kind, .question)
        XCTAssertEqual(InputWait.detect(screen: "Enter a name for the branch:")?.kind, .question)
    }
}

final class ServerPortsTests: XCTestCase {
    func testLsofAndAncestry() {
        let lsof = "p501\ncnode\nn*:3000\nn[::]:3000\np777\ncpython3\nn127.0.0.1:8000\n"
        let l = ServerPorts.parseLsof(lsof)
        XCTAssertEqual(l.map(\.port), [3000, 8000])
        XCTAssertEqual(l.first?.process, "node")
        let parents = ServerPorts.parseParents("  501   400\n  400   300\n  300     1\n  777   1\n")
        XCTAssertTrue(ServerPorts.descends(501, from: 300, parents: parents))
        XCTAssertFalse(ServerPorts.descends(777, from: 300, parents: parents))
        XCTAssertFalse(ServerPorts.descends(501, from: 1, parents: parents))
    }

    func testAnnouncedPortsAndParsing() {
        XCTAssertEqual(ServerPorts.announcedPorts(in: "  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host"), [5173])
        XCTAssertEqual(ServerPorts.announcedPorts(in: "Server listening on port 8080"), [8080])
        XCTAssertEqual(ServerPorts.parsePort("localhost:3000"), 3000)
        XCTAssertEqual(ServerPorts.parsePort(":443"), 443)
        XCTAssertNil(ServerPorts.parsePort("99999"))
    }
}

final class CloudContextTests: XCTestCase {
    let kube = """
    apiVersion: v1
    clusters:
    - cluster:
        server: https://x
      name: prod-cluster
    contexts:
    - context:
        cluster: prod-cluster
        namespace: payments
        user: admin
      name: prod
    - name: dev
      context:
        cluster: dev
        user: me
    current-context: prod
    kind: Config
    """

    func testKubeAndOthers() {
        let files = ["/h/.kube/config": kube, "/h/.docker/config.json": #"{"currentContext":"colima"}"#,
                     "/h/.config/gcloud/active_config": "work\n", "/h/.config/gcloud/configurations/config_work": "[core]\nproject = acme-prod\n"]
        let c = CloudContext.current(vars: .init(awsProfile: "admin"), home: "/h", read: { files[$0] })
        XCTAssertEqual(c.kube, "prod")
        XCTAssertEqual(c.namespace, "payments")
        XCTAssertEqual(c.aws, "admin")
        XCTAssertEqual(c.docker, "colima")
        XCTAssertEqual(c.gcloud, "acme-prod")
        XCTAssertEqual(c.summary(showing: ["kube", "aws"]), "prod/payments · aws:admin")
        XCTAssertEqual(CloudContext.kubeContextNames(vars: .init(), home: "/h", read: { files[$0] }), ["prod", "dev"])
    }

    func testToolsAndProfiles() {
        XCTAssertEqual(CloudContext.tools(in: "kubectl get pods -n x"), ["kube"])
        XCTAssertEqual(CloudContext.tools(in: "aws s3 ls | head"), ["aws"])
        XCTAssertTrue(CloudContext.tools(in: "ls -la").isEmpty)
        var p = Profile(badge: "PROD", confirm: ["*delete*"])
        p.kubeContext = "prod*"
        XCTAssertTrue(p.matches(context: CloudContext(kube: "prod-eu")))
        XCTAssertFalse(p.matches(context: CloudContext(kube: "dev")))
        XCTAssertEqual(Profile.resolve([p], context: CloudContext(kube: "prod")), p)
        XCTAssertEqual(ShellEvent.parse("ctx\tadmin\t\t\t"), .context(.init(awsProfile: "admin")))
    }

    func testAwsProfiles() {
        let files = ["/h/.aws/config": "[default]\nregion=x\n[profile prod]\n[sso-session corp]\n", "/h/.aws/credentials": "[dev]\n[prod]\n"]
        XCTAssertEqual(CloudContext.awsProfiles(home: "/h", read: { files[$0] }), ["default", "prod", "dev"])
    }
}

final class OutputFilterTests: XCTestCase {
    func testLevelsQueryAndFold() {
        let text = """
        Compiling a
        Downloading 1/100
        Downloading 2/100
        Downloading 3/100
        warning: unused variable
        error: cannot find 'x' in scope
        Build finished: 0 errors
        """
        XCTAssertEqual(OutputFilter.level(of: "error: cannot find"), .error)
        XCTAssertEqual(OutputFilter.level(of: "Build finished: 0 errors"), .normal)
        XCTAssertEqual(OutputFilter.level(of: "npm WARN deprecated"), .warning)
        let all = OutputFilter.apply(text, .init())
        let folded = all.first { $0.text.hasPrefix("Downloading") }
        XCTAssertEqual(folded?.count, 3)
        XCTAssertEqual(folded?.text, "Downloading 3/100")
        XCTAssertEqual(OutputFilter.apply(text, .init(minimumLevel: .error)).map(\.text), ["error: cannot find 'x' in scope"])
        XCTAssertEqual(OutputFilter.apply(text, .init(minimumLevel: .warning)).count, 2)
        XCTAssertEqual(OutputFilter.apply(text, .init(query: "scope cannot")).count, 1)
        XCTAssertEqual(OutputFilter.apply(text, .init(query: "^Down.*2", regex: true)).count, 1)
        XCTAssertEqual(OutputFilter.counts(text).errors, 1)
    }
}

final class ProjectTasksTests: XCTestCase {
    func testNpmMakeJust() {
        let files: [String: String] = [
            "/p/package.json": #"{"scripts":{"build":"tsc","dev":"vite","pretest":"x","test":"vitest","prettier":"p"}}"#,
            "/p/pnpm-lock.yaml": "",
            "/p/Makefile": "# Build it\nbuild: deps\n\tgo build\nVAR = 1\n.PHONY: build\nclean: ## remove output\n\trm -rf out\n",
            "/p/justfile": "set shell := [\"bash\"]\n# start the db\ndb:\n  docker compose up\n_private:\n  x\n",
        ]
        let p = ProjectTasks.find(from: "/p/src/deep", home: "/", exists: { files[$0] != nil }, read: { files[$0] })
        XCTAssertEqual(p?.root, "/p")
        let names = p?.tasks.map { "\($0.group):\($0.name)" } ?? []
        XCTAssertEqual(Array(names.prefix(4)), ["pnpm:dev", "pnpm:build", "pnpm:test", "pnpm:prettier"])
        XCTAssertFalse(names.contains("pnpm:pretest"))
        XCTAssertTrue(names.contains("make:build") && names.contains("make:clean") && names.contains("just:db"))
        XCTAssertFalse(names.contains("just:_private"))
        XCTAssertEqual(p?.tasks.first { $0.name == "clean" }?.detail, "remove output")
        XCTAssertEqual(p?.tasks.first { $0.name == "dev" }?.command, "pnpm dev")
    }

    func testNpmCommands() {
        let files = ["/q/package.json": #"{"scripts":{"start":"node .","lint":"eslint"}}"#]
        let t = ProjectTasks.tasks(in: "/q", exists: { files[$0] != nil }, read: { files[$0] })
        XCTAssertEqual(t.map(\.command), ["npm start", "npm run lint"])
    }
}

final class SecretRefsTests: XCTestCase {
    func testFindAndRewrite() {
        let cmd = "curl -H \"Authorization: Bearer {{secret:github-token}}\" https://api.github.com && psql {{op://Work/DB/password}}"
        XCTAssertEqual(SecretRefs.keychainNames(cmd), ["github-token"])
        let out = SecretRefs.rewrite(cmd) { "\"$(cat /tmp/\($0))\"" }
        XCTAssertEqual(out, "curl -H \"Authorization: Bearer \"$(cat /tmp/github-token)\"\" https://api.github.com && psql \"$(op read op://Work/DB/password)\"")
        XCTAssertNil(SecretRefs.rewrite(cmd) { _ in nil })
        XCTAssertFalse(SecretRefs.contains("echo {{name}}"))
    }

    func testWorkflowParamsSkipSecrets() {
        let w = Workflow(name: "x", steps: ["deploy {{env:staging}} --token {{secret:deploy}} {{op://v/i/f}}"])
        XCTAssertEqual(w.allParams.map(\.name), ["env"])
        XCTAssertEqual(w.render(["env": "prod"]), "deploy prod --token {{secret:deploy}} {{op://v/i/f}}")
    }
}

final class SSHReconnectTests: XCTestCase {
    func testPolicy() {
        XCTAssertTrue(SSHReconnect.shouldOffer(command: "ssh prod-web", exitCode: 255, duration: 600))
        XCTAssertFalse(SSHReconnect.shouldOffer(command: "ssh prod-web", exitCode: 255, duration: 2))
        XCTAssertFalse(SSHReconnect.shouldOffer(command: "ssh prod-web", exitCode: 0, duration: 600))
        XCTAssertFalse(SSHReconnect.shouldOffer(command: "ssh host uptime", exitCode: 255, duration: 60))
        XCTAssertFalse(SSHReconnect.shouldOffer(command: "make", exitCode: 255, duration: 60))
        XCTAssertTrue(SSHReconnect.shouldOffer(command: "ssh box # note", exitCode: 255, duration: 60))
        XCTAssertFalse(SSHReconnect.shouldOffer(command: "ssh box && echo hi", exitCode: 255, duration: 60))
        XCTAssertEqual(SSHReconnect.delay(attempt: 1), 2)
        XCTAssertEqual(SSHReconnect.delay(attempt: 9), 30)
        XCTAssertEqual(SSHReconnect.reconnectCommand("ssh -p 22 me@box"), "ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p 22 me@box")
    }
}

final class LineDiffTests: XCTestCase {
    func testDiff() {
        let a = "one\ntwo\nthree\nfour"
        let b = "one\n2\nthree\nfour\nfive"
        let d = LineDiff.diff(a, b)
        XCTAssertEqual(d.filter { $0.kind == .removed }.map(\.text), ["two"])
        XCTAssertEqual(d.filter { $0.kind == .added }.map(\.text), ["2", "five"])
        XCTAssertEqual(d.filter { $0.kind == .same }.count, 3)
        XCTAssertTrue(LineDiff.summary(LineDiff.diff("ok in 1.2s\nPASS 12", "ok in 3.4s\nPASS 12", ignoreNumbers: true)).identical)
        XCTAssertFalse(LineDiff.summary(LineDiff.diff("ok in 1.2s", "ok in 3.4s")).identical)
        XCTAssertEqual(LineDiff.diff("", "x").filter { $0.kind == .added }.map(\.text), ["x"])
    }

    func testDiffOrderMatchesInputs() {
        let a = (1...50).map { "line \($0)" }.joined(separator: "\n")
        var lines = (1...50).map { "line \($0)" }
        lines.remove(at: 10); lines.insert("new", at: 30)
        let d = LineDiff.diff(a, lines.joined(separator: "\n"))
        // Rebuilding the new text from same+added lines gives it back exactly.
        XCTAssertEqual(d.filter { $0.kind != .removed }.map(\.text), lines)
        XCTAssertEqual(d.filter { $0.kind != .added }.map(\.text), (1...50).map { "line \($0)" })
    }
}

final class StructuredOutputTests: XCTestCase {
    func testJSONAndTables() {
        guard case .json(let j)? = StructuredOutput.detect(#"[{"name":"a","age":3},{"name":"b","age":4}]"#) else { return XCTFail() }
        XCTAssertEqual(StructuredOutput.table(from: j)?.rows, [["3", "a"], ["4", "b"]])
        guard case .table(let csv, let src)? = StructuredOutput.detect("name,size\n\"a, b\",10\nc,20") else { return XCTFail() }
        XCTAssertEqual(src, "csv")
        XCTAssertEqual(csv.rows.first, ["a, b", "10"])
        let kubectl = """
        NAME                     READY   STATUS    RESTARTS   AGE
        web-7d4b9c-abcde         1/1     Running   0          5d
        worker-55f-xyz           0/1     Pending   3          2m
        """
        guard case .table(let k, let ks)? = StructuredOutput.detect(kubectl) else { return XCTFail() }
        XCTAssertEqual(ks, "columns")
        XCTAssertEqual(k.headers, ["NAME", "READY", "STATUS", "RESTARTS", "AGE"])
        XCTAssertEqual(k.rows[1], ["worker-55f-xyz", "0/1", "Pending", "3", "2m"])
        let docker = """
        CONTAINER ID   IMAGE          STATUS          NAMES
        1a2b3c4d5e6f   nginx:latest   Up 2 hours      web
        """
        guard case .table(let dk, _)? = StructuredOutput.detect(docker) else { return XCTFail() }
        XCTAssertEqual(dk.headers.first, "CONTAINER ID")
        XCTAssertEqual(dk.rows[0][2], "Up 2 hours")
        XCTAssertNil(StructuredOutput.detect("hello world\nthis is prose, with commas, here"))
        guard case .table(let nd, _)? = StructuredOutput.detect("{\"a\":1}\n{\"a\":2,\"b\":true}") else { return XCTFail() }
        XCTAssertEqual(nd.headers, ["a", "b"])
    }
}

final class HistorySyncTests: XCTestCase {
    func testTwoMacsShareHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-sync-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = HistoryStore(path: dir + "/a.sqlite"), b = HistoryStore(path: dir + "/b.sqlite")
        let folder = dir + "/shared"
        let id = a.recordStart(command: "make deploy", cwd: "/w", session: nil)
        a.recordFinish(id: id, exitCode: 0, duration: 3)
        let r1 = HistorySync.run(folder: folder, machine: "mac-a", store: a)
        XCTAssertEqual(r1.sent, 1)
        let r2 = HistorySync.run(folder: folder, machine: "mac-b", store: b)
        XCTAssertEqual(r2.received, 1)
        XCTAssertEqual(r2.otherMacs, ["mac-a"])
        XCTAssertEqual(b.search("deploy").first?.0.command, "make deploy")
        // Nothing is sent twice, and imported commands aren't sent back.
        XCTAssertEqual(HistorySync.run(folder: folder, machine: "mac-a", store: a).sent, 0)
        XCTAssertEqual(HistorySync.run(folder: folder, machine: "mac-b", store: b).sent, 0)
        XCTAssertEqual(HistorySync.run(folder: folder, machine: "mac-b", store: b).received, 0)
        // A command still running waits until it finishes.
        _ = a.recordStart(command: "npm run dev", cwd: "/w", session: nil)
        XCTAssertEqual(HistorySync.run(folder: folder, machine: "mac-a", store: a).sent, 0)
    }

    func testPreviousRun() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-prev-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let h = HistoryStore(path: dir + "/h.sqlite")
        let one = h.recordStart(command: "npm test", cwd: nil, session: nil)
        h.saveOutput("3 passing", forHistoryID: one)
        let two = h.recordStart(command: "npm test", cwd: nil, session: nil)
        h.saveOutput("2 passing\n1 failing", forHistoryID: two)
        XCTAssertEqual(h.previousRun(of: "npm test", beforeID: two)?.output, "3 passing")
        XCTAssertNil(h.previousRun(of: "npm test", beforeID: one))
    }
}

final class AnserLinkTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(AnserLink.parse(URL(string: "anser://new?dir=~/code")!, home: "/Users/me"), AnserLink(action: .new, dir: "/Users/me/code"))
        XCTAssertEqual(AnserLink.parse(URL(string: "anser://run?dir=/tmp&cmd=make%20test&window=1")!),
                       AnserLink(action: .run, dir: "/tmp", command: "make test", newWindow: true))
        XCTAssertNil(AnserLink.parse(URL(string: "anser://run?dir=/tmp")!))
        XCTAssertNil(AnserLink.parse(URL(string: "anser://new?dir=relative/path")!))
        XCTAssertNil(AnserLink.parse(URL(string: "anser://delete")!))
        XCTAssertNil(AnserLink.parse(URL(string: "https://new?dir=/tmp")!))
        XCTAssertFalse(WhatsNew.items.isEmpty)
    }
}
