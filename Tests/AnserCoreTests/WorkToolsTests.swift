import Foundation
import XCTest
@testable import AnserCore

final class TestFailuresTests: XCTestCase {
    func testPytest() throws {
        let out = """
        ============================= FAILURES =============================
        ___________________________ test_add ___________________________

            def test_add():
        >       assert add(1, 2) == 4
        E       assert 3 == 4

        tests/test_math.py:7: AssertionError
        ______________________ TestUser.test_name ______________________
        tests/test_user.py:21: KeyError
        ===================== short test summary info =====================
        FAILED tests/test_math.py::test_add - assert 3 == 4
        FAILED tests/test_user.py::TestUser::test_name - KeyError: 'name'
        ================= 2 failed, 10 passed in 0.12s =================
        """
        let r = try XCTUnwrap(TestFailures.report(command: "uv run pytest -x", output: out))
        XCTAssertEqual(r.runner, .pytest)
        XCTAssertEqual(r.failures.map(\.name), ["test_add", "TestUser::test_name"])
        XCTAssertEqual(r.failures[0].location, "tests/test_math.py:7")
        XCTAssertEqual(r.failures[1].line, 21)
        XCTAssertEqual(r.failures[0].message, "assert 3 == 4")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures[0], runner: .pytest, original: "uv run pytest -x"), "uv run pytest tests/test_math.py::test_add")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures, runner: .pytest, original: "pytest"),
                       "pytest tests/test_math.py::test_add tests/test_user.py::TestUser::test_name")
    }

    func testJestThroughNpm() throws {
        let out = """
        > app@1.0.0 test
        > jest

        FAIL src/math.test.js
          ● math › adds numbers

            expect(received).toBe(expected) // Object.is equality

              4 | test('adds numbers', () => {
            > 5 |   expect(add(1, 2)).toBe(4);
                |                     ^
              at Object.<anonymous> (src/math.test.js:5:21)

        Tests:       1 failed, 3 passed, 4 total
        """
        let r = try XCTUnwrap(TestFailures.report(command: "npm test", output: out))
        XCTAssertEqual(r.runner, .jest)
        XCTAssertEqual(r.failures.first?.name, "math adds numbers")
        XCTAssertEqual(r.failures.first?.location, "src/math.test.js:5")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures[0], runner: .jest, original: "npm test"), "npx jest src/math.test.js -t 'math adds numbers'")
    }

    func testVitest() throws {
        let out = """
         FAIL  src/sum.test.ts > sum > handles negatives
        AssertionError: expected -1 to be 1
         ❯ src/sum.test.ts:9:22
        """
        let r = try XCTUnwrap(TestFailures.report(command: "npx vitest", output: out))
        XCTAssertEqual(r.runner, .vitest)
        XCTAssertEqual(r.failures.first?.name, "sum handles negatives")
        XCTAssertEqual(r.failures.first?.line, 9)
        XCTAssertEqual(TestFailures.rerunCommand(r.failures[0], runner: .vitest, original: "npx vitest"), "npx vitest run src/sum.test.ts -t 'sum handles negatives'")
    }

    func testGo() throws {
        let out = """
        --- FAIL: TestParse (0.00s)
            --- FAIL: TestParse/empty (0.00s)
                parse_test.go:18: got "x", want ""
        FAIL
        FAIL\texample.com/app/parser\t0.004s
        ok  \texample.com/app/other\t0.002s
        """
        let r = try XCTUnwrap(TestFailures.report(command: "go test ./...", output: out))
        XCTAssertEqual(r.runner, .go)
        XCTAssertEqual(r.failures.map(\.name), ["TestParse/empty"])
        XCTAssertEqual(r.failures[0].group, "example.com/app/parser")
        XCTAssertEqual(r.failures[0].location, "parse_test.go:18")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures[0], runner: .go, original: "go test ./..."),
                       "go test example.com/app/parser -run '^TestParse$/^empty$'")
    }

    func testSwift() throws {
        let out = """
        /Users/me/app/Tests/AppTests/MathTests.swift:12: error: -[AppTests.MathTests testAdd] : XCTAssertEqual failed: ("3") is not equal to ("4")
        ✘ Test parsesDates() recorded an issue at DateTests.swift:30:9: Expectation failed: (d == nil)
        """
        let r = try XCTUnwrap(TestFailures.report(command: "swift test", output: out))
        XCTAssertEqual(r.failures.map(\.name), ["testAdd", "parsesDates"])
        XCTAssertEqual(r.failures[0].group, "MathTests")
        XCTAssertEqual(r.failures[0].line, 12)
        XCTAssertEqual(TestFailures.rerunCommand(r.failures[0], runner: .swift, original: "swift test"), "swift test --filter MathTests/testAdd")
    }

    func testCargoAndRSpec() throws {
        let cargo = """
        ---- tests::it_adds stdout ----
        thread 'tests::it_adds' panicked at src/lib.rs:10:5:
        assertion `left == right` failed

        failures:
            tests::it_adds
        """
        let c = try XCTUnwrap(TestFailures.report(command: "cargo test", output: cargo))
        XCTAssertEqual(c.failures.first?.location, "src/lib.rs:10")
        XCTAssertEqual(TestFailures.rerunCommand(c.failures[0], runner: .cargo, original: "cargo test --release"), "cargo test tests::it_adds -- --exact")
        let rspec = "rspec ./spec/user_spec.rb:12 # User validates email\n"
        let r = try XCTUnwrap(TestFailures.report(command: "bundle exec rspec", output: rspec))
        XCTAssertEqual(r.failures.first?.name, "User validates email")
        XCTAssertEqual(TestFailures.rerunCommand(r.failures, runner: .rspec, original: "bundle exec rspec"), "bundle exec rspec ./spec/user_spec.rb:12")
    }

    func testNotTestOutput() {
        XCTAssertNil(TestFailures.report(command: "ls", output: "README.md\nSources\n"))
        XCTAssertNil(TestFailures.report(command: "make", output: "error: something broke\n"))
    }
}

final class ProjectEnvTests: XCTestCase {
    func testWatchRules() {
        XCTAssertTrue(WatchRules.isIgnored("node_modules/x/index.js"))
        XCTAssertTrue(WatchRules.isIgnored(".git/index"))
        XCTAssertTrue(WatchRules.isIgnored("src/.main.swift.swp"))
        XCTAssertTrue(WatchRules.isIgnored("build/out.o"))
        XCTAssertFalse(WatchRules.isIgnored("src/main.swift"))
        XCTAssertFalse(WatchRules.isIgnored("Package.swift"))
    }

    func testFind() {
        let files: Set<String> = ["/h/p/.git", "/h/p/.env", "/h/p/.venv/bin/activate", "/h/p/.nvmrc"]
        let f = ProjectEnv.find(from: "/h/p/src/app", home: "/h", exists: { files.contains($0) }, read: { $0 == "/h/p/.nvmrc" ? "v20.11\n" : nil })
        XCTAssertEqual(f?.root, "/h/p")
        XCTAssertEqual(f?.dotenvFiles, [".env"])
        XCTAssertEqual(f?.venv, ".venv")
        XCTAssertEqual(f?.nodeVersion, "v20.11")
        XCTAssertEqual(f?.summary, ".env · .venv · node 20.11")
        // Stops at the repo root and at home.
        XCTAssertNil(ProjectEnv.find(from: "/h/q", home: "/h", exists: { _ in false }, read: { _ in nil }))
        XCTAssertNil(ProjectEnv.find(from: "/h", home: "/h", exists: { _ in true }, read: { _ in nil }))
    }

    func testParseDotenv() {
        let text = """
        # comment
        export API_URL=https://x.test/api # trailing
        NAME="Ada Lovelace"
        QUOTED='it''s'
        MULTI="line1\\nline2"
        PATH=/evil/bin
        DYLD_INSERT_LIBRARIES=/x.dylib
        bad key=1
        EMPTY=
        """
        let v = ProjectEnv.parseDotenv(text)
        let d = Dictionary(v.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
        XCTAssertEqual(d["API_URL"], "https://x.test/api")
        XCTAssertEqual(d["NAME"], "Ada Lovelace")
        XCTAssertEqual(d["MULTI"], "line1\nline2")
        XCTAssertEqual(d["EMPTY"], "")
        XCTAssertNil(d["PATH"])
        XCTAssertNil(d["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(d["bad key"])
    }

    func testLoadScriptQuotesValues() {
        var f = ProjectEnv.Found(root: "/p")
        f.dotenvFiles = [".env"]
        f.venv = ".venv"
        f.nodeVersion = "20"
        let (script, loaded) = ProjectEnv.loadScript(f, values: [("A", "x'; rm -rf ~ #"), ("A", "two"), ("B", "$(whoami)")], shell: .posix,
                                                     tools: .init(nvm: true), activeVenv: nil)
        XCTAssertTrue(script.contains("export A='two'"), script)
        XCTAssertTrue(script.contains("export B='$(whoami)'"), script)
        XCTAssertTrue(script.contains("source '/p/.venv/bin/activate'"))
        XCTAssertTrue(script.contains("nvm use '20'"))
        XCTAssertEqual(loaded.keys, ["A", "B"])
        XCTAssertTrue(loaded.venv && loaded.node)
        let fish = ProjectEnv.loadScript(f, values: [("A", "it's")], shell: .fish, tools: .init(), activeVenv: "/p/.venv").script
        XCTAssertTrue(fish.contains("set -gx A 'it\\'s'"), fish)
        XCTAssertFalse(fish.contains("activate"), "already active")
        let un = ProjectEnv.unloadScript(loaded, shell: .posix)
        XCTAssertTrue(un.contains("unset A B") && un.contains("deactivate"))
    }
}

final class RunbookTests: XCTestCase {
    func testParse() {
        let md = """
        # Deploy

        Ship the app.

        ## Check

        Make sure it's clean.

        ```sh
        git status
        ```

        ## Build
        ```console
        $ make build
        building…
        $ make test
        ```

        ```json
        {"not": "a step"}
        ```

        ## Release
        ```bash
        ./release.sh {{version:1.0}} \\
          --notes notes.md
        ```

        ## After
        Tell the team.
        """
        let r = Runbook.parse(md, fallbackTitle: "x")
        XCTAssertEqual(r.title, "Deploy")
        XCTAssertEqual(r.intro, "Ship the app.")
        XCTAssertEqual(r.steps.map(\.title), ["Check", "Build", "Release"])
        XCTAssertEqual(r.steps[0].text, "Make sure it's clean.")
        XCTAssertEqual(r.steps[1].command, "make build && make test")
        XCTAssertTrue(r.steps[2].command.contains("\\\n"))
        XCTAssertTrue(r.outro.contains("Tell the team"))
        XCTAssertEqual(r.params.map(\.name), ["version"])
        XCTAssertTrue(r.render(step: 2, values: ["version": "2.0"]).hasPrefix("./release.sh 2.0"))
        XCTAssertFalse(Runbook.parse(Runbook.template(title: "T"), fallbackTitle: "T").steps.isEmpty)
    }
}

final class ContainerTests: XCTestCase {
    func testDocker() {
        let out = """
        {"ID":"abc123def4567890","Image":"postgres:16","Names":"db","Ports":"0.0.0.0:5432->5432/tcp","State":"running","Status":"Up 2 hours"}
        {"ID":"ff","Image":"redis","Names":"cache","Ports":"","State":"exited","Status":"Exited (0) 3 days ago"}
        Cannot connect to the Docker daemon
        """
        let c = Containers.parseDocker(out)
        XCTAssertEqual(c.map(\.name), ["db", "cache"])
        XCTAssertEqual(c[0].hostPort, 5432)
        XCTAssertTrue(c[0].isRunning)
        XCTAssertFalse(c[1].isRunning)
        XCTAssertEqual(c[0].id, "abc123def456")
        XCTAssertEqual(Containers.logs(c[0]), "docker logs -f --tail 200 db")
    }

    func testPods() throws {
        let json = """
        {"items":[
          {"metadata":{"name":"web-1","namespace":"prod"},"spec":{"containers":[{"name":"web"}]},
           "status":{"phase":"Running","containerStatuses":[{"ready":true,"restartCount":0,"state":{"running":{}}}]}},
          {"metadata":{"name":"worker-2","namespace":"prod"},"spec":{"containers":[{"name":"w"}]},
           "status":{"phase":"Running","containerStatuses":[{"ready":false,"restartCount":7,"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}
        ]}
        """
        let pods = try XCTUnwrap(Containers.parsePods(json))
        XCTAssertEqual(pods.map(\.name), ["worker-2", "web-1"], "unhealthy first")
        XCTAssertEqual(pods[0].statusText, "CrashLoopBackOff · 7 restarts")
        XCTAssertTrue(pods[1].isHealthy)
        XCTAssertNil(Containers.parsePods("error: You must be logged in"))
        XCTAssertEqual(Containers.logs(pods[1]), "kubectl logs -f --tail=200 -n prod web-1")
    }

    func testTunnel() {
        let t = SSHTunnel(name: "db", host: "bastion", localPort: 5433, remoteHost: "db.internal", remotePort: 5432)
        XCTAssertNil(t.problem)
        XCTAssertEqual(Array(t.argv().suffix(4)), ["-L", "127.0.0.1:5433:db.internal:5432", "--", "bastion"])
        XCTAssertTrue(t.argv().contains("BatchMode=yes"))
        XCTAssertNotNil(SSHTunnel(name: "", host: "-oProxyCommand=x", localPort: 1, remotePort: 2).problem)
        XCTAssertNotNil(SSHTunnel(name: "", host: "h", localPort: 0, remotePort: 2).problem)
        let decoded = try? JSONDecoder().decode(SSHTunnel.self, from: Data(#"{"name":"x","host":"h","localPort":1,"remoteHost":"localhost","remotePort":2}"#.utf8))
        XCTAssertEqual(decoded?.remotePort, 2)
    }

    func testSCPOptions() throws {
        let o = try XCTUnwrap(SSHCopy.options(fromSSH: "ssh -p 2222 -i ~/.ssh/k -l deploy -C web.example.com"))
        XCTAssertEqual(o.target, "deploy@web.example.com")
        XCTAssertEqual(o.options, ["-P", "2222", "-i", "~/.ssh/k", "-C"])
        let up = SSHCopy.uploadArgv(files: ["/tmp/a b.txt"], to: "/srv/app", options: o.options, target: o.target)
        XCTAssertEqual(Array(up.suffix(2)), ["/tmp/a b.txt", "deploy@web.example.com:/srv/app/"])
        XCTAssertEqual(SSHCopy.remotePath("logs/x.log", remoteCwd: "/srv"), "/srv/logs/x.log")
        XCTAssertEqual(SSHCopy.remotePath("/etc/hosts", remoteCwd: "/srv"), "/etc/hosts")
        XCTAssertNil(SSHCopy.options(fromSSH: "ls -la"))
    }

    func testCommandRisk() {
        XCTAssertNotNil(CommandRisk.reason("rm -rf build"))
        XCTAssertNotNil(CommandRisk.reason("git push --force origin main"))
        XCTAssertNotNil(CommandRisk.reason("curl -fsSL https://x.sh | sh"))
        XCTAssertNotNil(CommandRisk.reason("kubectl delete pod web-1"))
        XCTAssertNil(CommandRisk.reason("ls -la"))
        XCTAssertNil(CommandRisk.reason("git status && npm test"))
    }
}

final class AgentTests: XCTestCase {
    func testReplies() {
        XCTAssertEqual(AgentReply.parse("Look at the failing tests first.\n\n```sh\nnpm test -- --silent\n```"),
                       .run(command: "npm test -- --silent", why: "Look at the failing tests first."))
        XCTAssertEqual(AgentReply.parse("DONE: Upgraded eslint and fixed 3 errors."), .done(summary: "Upgraded eslint and fixed 3 errors."))
        XCTAssertEqual(AgentReply.parse("QUESTION: Which environment, staging or prod?"), .ask(question: "Which environment, staging or prod?"))
    }

    func testPromptHasHistoryAndRedacts() {
        let steps = [AgentStep(command: "export TOKEN=abc123secret", exitCode: 0, output: "ok"),
                     AgentStep(command: "rm -rf /", skipped: true, note: "no way"),
                     AgentStep(command: "", note: "use staging")]
        let p = AIHelp.agentPrompt(goal: "deploy", steps: steps, context: .init(shell: "zsh", os: "macOS", cwdName: "app", gitBranch: "main"))
        XCTAssertTrue(p.contains("Task: deploy"))
        XCTAssertFalse(p.contains("abc123secret"))
        XCTAssertTrue(p.contains("The user skipped this command: no way"))
        XCTAssertTrue(p.contains("(the user said) use staging"))
        XCTAssertTrue(p.contains("DONE:"))
    }
}

final class PluginExtrasTests: XCTestCase {
    func testGalleryInstallsValidPlugins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-gallery-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for item in PluginGallery.items { try PluginGallery.install(item, into: dir) }
        let (plugins, errors) = PluginRegistry.load(from: dir)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(Set(plugins.map(\.id)), Set(PluginGallery.items.map(\.id)))
        let prs = try XCTUnwrap(plugins.first { $0.id == "pull-requests" })
        XCTAssertEqual(prs.manifest.settings?.first?.envName, "ANSER_SETTING_LIMIT")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir + "/todo-count/todos.sh"))
        // Every script is valid sh.
        for item in PluginGallery.items {
            for name in item.files.keys where name.hasSuffix(".sh") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-n", dir + "/" + item.id + "/" + name]
                try p.run(); p.waitUntilExit()
                XCTAssertEqual(p.terminationStatus, 0, "\(item.id)/\(name)")
            }
        }
    }

    func testProjectPluginsAndTrust() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anser-proj-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/.anser/plugins/team", withIntermediateDirectories: true)
        try #"{"name":"Team","chips":[{"id":"x","script":"echo hi"}]}"#.write(toFile: root + "/.anser/plugins/team/plugin.json", atomically: true, encoding: .utf8)
        let (p, _) = PluginRegistry.loadProject(cwd: root + "/src")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].source, .project)
        XCTAssertTrue(p[0].key.hasPrefix("project:"))
        let defaults = ScratchDefaults.make("anser-test-plugin-trust")
        defer { ScratchDefaults.discard("anser-test-plugin-trust") }
        let trust = FileTrust("t", defaults: defaults)
        XCTAssertFalse(trust.isTrusted(p[0]))
        trust.trust(p[0])
        XCTAssertTrue(trust.isTrusted(p[0]))
        try "echo changed".write(toFile: root + "/.anser/plugins/team/x.sh", atomically: true, encoding: .utf8)
        XCTAssertFalse(trust.isTrusted(p[0]), "a new file asks again")
    }

    func testShellEvents() {
        XCTAssertEqual(ShellEvent.parse("caps\tload"), .capabilities(["load"]))
        if case let .context(v)? = ShellEvent.parse("ctx\t\t\t\t\t/p/.venv") { XCTAssertEqual(v.virtualEnv, "/p/.venv") } else { XCTFail() }
    }
}
