import Foundation

/// Finds failed tests in a test runner's output, so Anser can list them,
/// open each at its line and re-run just that test.
///
/// Knows pytest, Jest, Vitest, `go test`, `swift test` (XCTest and Swift
/// Testing), `cargo test` and RSpec. Works for wrappers like `npm test` or
/// `make test` too, by recognizing the runner's output.
public enum TestFailures {
    public enum Runner: String, Sendable, CaseIterable {
        case pytest, jest, vitest, go, swift, cargo, rspec, dotnet, phpunit, exunit, junit

        public var displayName: String {
            switch self {
            case .pytest: "pytest"
            case .jest: "Jest"
            case .vitest: "Vitest"
            case .go: "go test"
            case .swift: "swift test"
            case .cargo: "cargo test"
            case .rspec: "RSpec"
            case .dotnet: "dotnet test"
            case .phpunit: "PHPUnit"
            case .exunit: "ExUnit"
            case .junit: "JUnit"
            }
        }
    }

    public struct Failure: Sendable, Equatable {
        /// The test's name as its runner knows it ("TestParse/empty", "math › adds", "tests::it_adds").
        public var name: String
        /// File as printed (often relative to the folder the command ran in).
        public var file: String?
        public var line: Int?
        /// The first line of the failure message.
        public var message: String?
        /// Go package or Swift suite, when the runner needs it to re-run the test.
        public var group: String?

        public init(name: String, file: String? = nil, line: Int? = nil, message: String? = nil, group: String? = nil) {
            self.name = name; self.file = file; self.line = line; self.message = message; self.group = group
        }

        /// "file:line" for opening, when known.
        public var location: String? {
            guard let file else { return nil }
            return line.map { "\(file):\($0)" } ?? file
        }
    }

    public struct Report: Sendable, Equatable {
        public var runner: Runner
        public var failures: [Failure]
        public init(runner: Runner, failures: [Failure]) { self.runner = runner; self.failures = failures }
    }

    // MARK: Finding failures

    /// The failed tests in `output`, or nil when it isn't test output (or nothing failed).
    public static func report(command: String, output: String) -> Report? {
        let text = stripANSI(output)
        let candidates = runnerFromCommand(command).map { [$0] + Runner.allCases.filter { r in r != runnerFromCommand(command) } } ?? Runner.allCases
        for r in candidates {
            let f = parse(text, runner: r)
            if !f.isEmpty { return Report(runner: r, failures: dedupe(f)) }
        }
        return nil
    }

    /// The runner a command clearly calls, if any.
    public static func runnerFromCommand(_ command: String) -> Runner? {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { ($0 as Substring).lowercased() }
        func has(_ w: String) -> Bool { words.contains { ($0 as NSString).lastPathComponent == w } }
        if has("pytest") || has("py.test") { return .pytest }
        if has("vitest") { return .vitest }
        if has("jest") { return .jest }
        if let i = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "go" }), i + 1 < words.count, words[i + 1] == "test" { return .go }
        if let i = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "swift" }), i + 1 < words.count, words[i + 1] == "test" { return .swift }
        if let i = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "cargo" }), i + 1 < words.count, ["test", "nextest"].contains(words[i + 1]) { return .cargo }
        if has("rspec") { return .rspec }
        if has("phpunit") || has("pest") { return .phpunit }
        func sub(_ prog: String, _ word: String) -> Bool {
            guard let i = words.firstIndex(where: { ($0 as NSString).lastPathComponent == prog }), i + 1 < words.count else { return false }
            return words[(i + 1)...].contains(word)
        }
        if sub("dotnet", "test") { return .dotnet }
        if sub("mix", "test") { return .exunit }
        if sub("gradle", "test") || sub("gradlew", "test") || sub("mvn", "test") || sub("mvnw", "test") || sub("mvn", "verify") { return .junit }
        return nil
    }

    static func parse(_ text: String, runner: Runner) -> [Failure] {
        switch runner {
        case .pytest: parsePytest(text)
        case .jest: parseJest(text)
        case .vitest: parseVitest(text)
        case .go: parseGo(text)
        case .swift: parseSwift(text)
        case .cargo: parseCargo(text)
        case .rspec: parseRSpec(text)
        case .dotnet: parseDotnet(text)
        case .phpunit: parsePHPUnit(text)
        case .exunit: parseExUnit(text)
        case .junit: parseJUnit(text)
        }
    }

    private static func dedupe(_ f: [Failure]) -> [Failure] {
        var seen = Set<String>(), out: [Failure] = []
        for x in f where seen.insert((x.group ?? "") + "\u{0}" + x.name).inserted { out.append(x) }
        return out
    }

    // MARK: pytest

    static func parsePytest(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        // Where each failure's traceback points: section "____ name ____", then "file.py:12: Error".
        var locations: [String: [(String, Int, String)]] = [:]
        var current: String?
        let header = try! NSRegularExpression(pattern: #"^_{3,} (.+?) _{3,}$"#)
        let frame = try! NSRegularExpression(pattern: #"^([^\s:]+\.py):(\d+): (.*)$"#)
        for l in lines {
            if let m = match(header, l) { current = m[1]; continue }
            if let c = current, let m = match(frame, l), let n = Int(m[2]) { locations[c, default: []].append((m[1], n, m[3])) }
        }
        let failed = try! NSRegularExpression(pattern: #"^(?:FAILED|ERROR) ([^\s]+?\.py)::([^\s]+)(?: - (.*))?$"#)
        var out: [Failure] = []
        for l in lines {
            guard let m = match(failed, l) else { continue }
            let file = m[1], name = m[2]
            // The section header is "test_x" or "TestClass.test_x" (parametrized: "test_x[1]").
            let key = name.replacingOccurrences(of: "::", with: ".")
            let frames = locations[key] ?? locations[name.components(separatedBy: "::").last ?? name] ?? []
            let own = frames.last { $0.0 == file || file.hasSuffix("/" + $0.0) || $0.0.hasSuffix("/" + file) } ?? frames.last
            out.append(Failure(name: name, file: file, line: own?.1, message: m[3].isEmpty ? own?.2 : m[3]))
        }
        return out
    }

    // MARK: Jest

    static func parseJest(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        var out: [Failure] = []
        var file: String?
        let failLine = try! NSRegularExpression(pattern: #"^\s*FAIL\s+(\S+)"#)
        let bullet = try! NSRegularExpression(pattern: #"^\s*● (.+)$"#)
        let frame = try! NSRegularExpression(pattern: #"\(?([^\s()]+\.(?:[cm]?[jt]sx?)):(\d+):\d+\)?"#)
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if let m = match(failLine, l), !l.contains(" > ") { file = m[1]; i += 1; continue }
            if let m = match(bullet, l) {
                let title = m[1].trimmingCharacters(in: .whitespaces)
                if title.hasPrefix("Test suite failed to run") || title.hasPrefix("Console") { i += 1; continue }
                var f = Failure(name: title.replacingOccurrences(of: " › ", with: " "), file: file)
                var j = i + 1
                while j < lines.count, match(bullet, lines[j]) == nil, match(failLine, lines[j]) == nil {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if f.message == nil, !t.isEmpty, !t.hasPrefix("at ") { f.message = t }
                    if f.line == nil, let fm = match(frame, lines[j]), !fm[1].contains("node_modules") {
                        let base = (fm[1] as NSString).lastPathComponent
                        if file == nil || file!.hasSuffix(base) { f.line = Int(fm[2]); if f.file == nil { f.file = fm[1] } }
                    }
                    j += 1
                }
                out.append(f)
                i = j
                continue
            }
            i += 1
        }
        // Only trust this when it really looks like Jest.
        return text.contains("Tests:") || text.contains("FAIL ") ? out : []
    }

    // MARK: Vitest

    static func parseVitest(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        let fail = try! NSRegularExpression(pattern: #"^\s*(?:FAIL|×|✗)\s+(\S+\.(?:[cm]?[jt]sx?))\s+>\s+(.+?)(?:\s+\d+ms)?$"#)
        let frame = try! NSRegularExpression(pattern: #"❯\s+(\S+\.(?:[cm]?[jt]sx?)):(\d+):\d+"#)
        var out: [Failure] = []
        var i = 0
        while i < lines.count {
            if let m = match(fail, lines[i]) {
                let parts = m[2].components(separatedBy: " > ").map { $0.trimmingCharacters(in: .whitespaces) }
                var f = Failure(name: parts.joined(separator: " "), file: m[1])
                var j = i + 1
                while j < lines.count, j < i + 40, match(fail, lines[j]) == nil {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if f.message == nil, !t.isEmpty, !t.hasPrefix("❯"), !t.hasPrefix("⎯"), !t.hasPrefix("FAIL") { f.message = t }
                    if f.line == nil, let fm = match(frame, lines[j]), m[1].hasSuffix((fm[1] as NSString).lastPathComponent) { f.line = Int(fm[2]) }
                    j += 1
                }
                out.append(f)
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: go test

    static func parseGo(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        let fail = try! NSRegularExpression(pattern: #"^\s*--- FAIL: (\S+)"#)
        let loc = try! NSRegularExpression(pattern: #"^\s+(\S+_test\.go):(\d+): (.*)$"#)
        let pkg = try! NSRegularExpression(pattern: #"^FAIL\s+(\S+)\s+[\d.]+s"#)
        let runLine = try! NSRegularExpression(pattern: #"^=== (?:RUN|CONT|PAUSE)\s+(\S+)"#)
        var out: [Failure] = []
        var pending: [Int] = []          // failures waiting for their package line
        var current: String?             // test being run (with -v, its log lines come before "--- FAIL")
        var locs: [String: (String, Int, String)] = [:]
        var afterFail = false            // without -v, log lines come right after "--- FAIL"
        for l in lines {
            if let m = match(runLine, l) { current = m[1]; afterFail = false; continue }
            if let m = match(loc, l), let n = Int(m[2]) {
                if afterFail, let i = out.indices.last, out[i].file == nil {
                    out[i].file = m[1]; out[i].line = n; out[i].message = m[3]
                } else if let c = current, locs[c] == nil {
                    locs[c] = (m[1], n, m[3])
                }
                continue
            }
            if let m = match(fail, l) {
                var f = Failure(name: m[1])
                if let x = locs[m[1]] { f.file = x.0; f.line = x.1; f.message = x.2 }
                out.append(f)
                pending.append(out.count - 1)
                afterFail = true
                continue
            }
            if let m = match(pkg, l) {
                for i in pending { out[i].group = m[1] }
                pending = []
                afterFail = false
            }
        }
        // A parent test fails when a subtest does; keep only the most specific ones.
        let names = Set(out.map(\.name))
        return out.filter { f in !names.contains { $0.hasPrefix(f.name + "/") } }
    }

    // MARK: swift test

    static func parseSwift(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        // XCTest: "/path/FooTests.swift:42: error: -[Mod.FooTests testBar] : XCTAssertEqual failed…"
        let xc = try! NSRegularExpression(pattern: #"^(\S.*?\.swift):(\d+): error: (?:-\[)?(?:\w+\.)?(\w+)[ .](\w+)\]? : (.*)$"#)
        // Swift Testing: "✘ Test bar() recorded an issue at FooTests.swift:12:5: Expectation failed: …"
        let st = try! NSRegularExpression(pattern: #"^\s*[✘✗x] Test (.+?) recorded an issue at (\S+\.swift):(\d+):\d+: (.*)$"#)
        var out: [Failure] = []
        for l in lines {
            if let m = match(xc, l) {
                out.append(Failure(name: m[4], file: m[1], line: Int(m[2]), message: m[5], group: m[3]))
            } else if let m = match(st, l) {
                var name = m[1].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count > 1 { name = String(name.dropFirst().dropLast()) }
                if name.hasSuffix("()") { name = String(name.dropLast(2)) }
                out.append(Failure(name: name, file: m[2], line: Int(m[3]), message: m[4]))
            }
        }
        return out
    }

    // MARK: cargo test

    static func parseCargo(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        let head = try! NSRegularExpression(pattern: #"^---- (\S+) stdout ----$"#)
        // "thread 'x' panicked at src/lib.rs:10:5:" (new) or "panicked at 'msg', src/lib.rs:10:5" (old)
        let panic = try! NSRegularExpression(pattern: #"panicked at (?:'(.*)', )?([^\s:]+\.rs):(\d+):\d+:?$"#)
        var out: [Failure] = []
        var i = 0
        while i < lines.count {
            if let m = match(head, lines[i]) {
                var f = Failure(name: m[1])
                var j = i + 1
                while j < lines.count, match(head, lines[j]) == nil, !lines[j].hasPrefix("failures:") {
                    if f.file == nil, let p = match(panic, lines[j]) {
                        f.file = p[2]; f.line = Int(p[3])
                        if !p[1].isEmpty { f.message = p[1] }
                        else if j + 1 < lines.count { f.message = lines[j + 1].trimmingCharacters(in: .whitespaces) }
                    }
                    j += 1
                }
                out.append(f)
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: RSpec

    static func parseRSpec(_ text: String) -> [Failure] {
        let r = try! NSRegularExpression(pattern: #"^rspec (\S+?):(\d+) # (.*)$"#)
        return text.components(separatedBy: "\n").compactMap { l in
            guard let m = match(r, l) else { return nil }
            return Failure(name: m[3], file: m[1], line: Int(m[2]))
        }
    }

    // MARK: dotnet test

    static func parseDotnet(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        let fail = try! NSRegularExpression(pattern: #"^\s*Failed (\S+) \[[^\]]*\]\s*$"#)
        let at = try! NSRegularExpression(pattern: #"\bin (\S.*?\.(?:cs|fs|vb)):line (\d+)"#)
        var out: [Failure] = []
        var i = 0
        while i < lines.count {
            if let m = match(fail, lines[i]) {
                var f = Failure(name: m[1])
                var j = i + 1
                while j < lines.count, j < i + 40, match(fail, lines[j]) == nil {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if f.message == nil, !t.isEmpty, t != "Error Message:", t != "Stack Trace:" { f.message = t }
                    if f.file == nil, let a = match(at, lines[j]) { f.file = a[1]; f.line = Int(a[2]) }
                    j += 1
                }
                out.append(f)
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: PHPUnit

    static func parsePHPUnit(_ text: String) -> [Failure] {
        guard text.contains("FAILURES!") || text.contains("There was 1 failure") || text.contains("There were") || text.contains("ERRORS!") else { return [] }
        let lines = text.components(separatedBy: "\n")
        let head = try! NSRegularExpression(pattern: #"^\d+\) (\S+?)::(\w+)"#)
        let loc = try! NSRegularExpression(pattern: #"^(/\S+?\.php|\S+?\.php):(\d+)$"#)
        var out: [Failure] = []
        var i = 0
        while i < lines.count {
            if let m = match(head, lines[i]) {
                var f = Failure(name: m[2], group: m[1])
                var j = i + 1
                while j < lines.count, j < i + 40, match(head, lines[j]) == nil {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if f.message == nil, !t.isEmpty { f.message = t }
                    // The test file's own line, not the framework's.
                    if let l = match(loc, t), !l[1].contains("/vendor/") { f.file = l[1]; f.line = Int(l[2]) }
                    j += 1
                }
                out.append(f)
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    // MARK: ExUnit (mix test)

    static func parseExUnit(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        let head = try! NSRegularExpression(pattern: #"^\s*\d+\) test (.+) \(([\w.]+)\)\s*$"#)
        let loc = try! NSRegularExpression(pattern: #"^\s*(\S+\.exs?):(\d+)\s*$"#)
        var out: [Failure] = []
        for (i, l) in lines.enumerated() {
            guard let m = match(head, l) else { continue }
            var f = Failure(name: m[1], group: m[2])
            for j in (i + 1)..<min(lines.count, i + 4) { if let x = match(loc, lines[j]) { f.file = x[1]; f.line = Int(x[2]); break } }
            if let msg = lines[(i + 1)..<min(lines.count, i + 12)].map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("Assertion") || $0.hasPrefix("**") || $0.hasPrefix("code:") }) { f.message = msg }
            out.append(f)
        }
        return out
    }

    // MARK: JUnit (Gradle, Maven)

    static func parseJUnit(_ text: String) -> [Failure] {
        let lines = text.components(separatedBy: "\n")
        // Gradle: "MathTest > addsNumbers() FAILED", then "    ...Error at MathTest.java:12"
        let gradle = try! NSRegularExpression(pattern: #"^\s*([\w.$]+) > (.+?)\(\)?(?:\[\d+\])? FAILED\s*$"#)
        let gradleAt = try! NSRegularExpression(pattern: #"at (\S+\.(?:java|kt)):(\d+)"#)
        // Maven: "[ERROR]   MathTest.addsNumbers:12 expected: <4> but was: <3>"
        let maven = try! NSRegularExpression(pattern: #"^\[ERROR\]\s+([\w.$]+)\.(\w+):(\d+)\s*(.*)$"#)
        var out: [Failure] = []
        for (i, l) in lines.enumerated() {
            if let m = match(gradle, l) {
                var name = m[2]
                if name.hasSuffix("(") { name.removeLast() }
                var f = Failure(name: name, group: m[1])
                for j in (i + 1)..<min(lines.count, i + 6) {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    if f.message == nil, !t.isEmpty { f.message = t }
                    if let a = match(gradleAt, lines[j]) { f.file = a[1]; f.line = Int(a[2]); break }
                }
                out.append(f)
            } else if let m = match(maven, l) {
                let cls = m[1]
                out.append(Failure(name: m[2], file: (cls.split(separator: ".").last.map(String.init) ?? cls) + ".java", line: Int(m[3]),
                                   message: m[4].isEmpty ? nil : m[4], group: cls))
            }
        }
        return out
    }

    // MARK: Re-running

    /// A command that runs only this failed test, built from the original command when possible.
    public static func rerunCommand(_ f: Failure, runner: Runner, original: String) -> String? {
        rerunCommand([f], runner: runner, original: original)
    }

    /// A command that runs only these failed tests (nil when the runner can't, e.g. several cargo tests).
    public static func rerunCommand(_ fs: [Failure], runner: Runner, original: String) -> String? {
        guard !fs.isEmpty else { return nil }
        let q = quote
        switch runner {
        case .pytest:
            let ids = fs.compactMap { f in f.file.map { "\($0)::\(f.name)" } }
            guard !ids.isEmpty else { return nil }
            return prefix(original, through: ["pytest", "py.test"], fallback: "pytest") + " " + ids.map(q).joined(separator: " ")
        case .jest:
            let files = Array(Set(fs.compactMap(\.file))).sorted()
            let pattern = fs.map { regexEscape($0.name) }.joined(separator: "|")
            return prefix(original, through: ["jest"], fallback: "npx jest") + (files.isEmpty ? "" : " " + files.map(q).joined(separator: " ")) + " -t " + q(pattern)
        case .vitest:
            let files = Array(Set(fs.compactMap(\.file))).sorted()
            var p = prefix(original, through: ["vitest"], fallback: "npx vitest")
            if !p.split(separator: " ").contains("run") { p += " run" }
            let pattern = fs.map { regexEscape($0.name) }.joined(separator: "|")
            return p + (files.isEmpty ? "" : " " + files.map(q).joined(separator: " ")) + " -t " + q(pattern)
        case .go:
            let pkgs = Array(Set(fs.compactMap(\.group))).sorted()
            let tops = fs.map { f -> String in
                f.name.split(separator: "/").map { "^" + regexEscape(String($0)) + "$" }.joined(separator: "/")
            }
            let pattern = tops.count == 1 ? tops[0] : "(" + fs.map { "^" + regexEscape(String($0.name.split(separator: "/").first ?? "")) + "$" }.joined(separator: "|") + ")"
            return "go test " + (pkgs.isEmpty ? "./..." : pkgs.map(q).joined(separator: " ")) + " -run " + q(pattern)
        case .swift:
            let filters = fs.map { f in (f.group.map { $0 + "/" } ?? "") + f.name }
            return "swift test --filter " + q(filters.count == 1 ? filters[0] : filters.map(regexEscape).joined(separator: "|"))
        case .cargo:
            guard fs.count == 1 else { return nil }
            return prefix(original, through: ["test", "nextest"], fallback: "cargo test") + " " + q(fs[0].name) + " -- --exact"
        case .rspec:
            let locs = fs.compactMap(\.location)
            guard !locs.isEmpty else { return nil }
            return prefix(original, through: ["rspec"], fallback: "rspec") + " " + locs.map(q).joined(separator: " ")
        case .dotnet:
            return "dotnet test --filter " + q(fs.map { "FullyQualifiedName~" + $0.name }.joined(separator: "|"))
        case .phpunit:
            let p = prefix(original, through: ["phpunit", "pest"], fallback: "vendor/bin/phpunit")
            return p + " --filter " + q(fs.map { regexEscape($0.name) }.joined(separator: "|"))
        case .exunit:
            let locs = fs.compactMap(\.location)
            guard !locs.isEmpty else { return nil }
            return "mix test " + locs.map(q).joined(separator: " ")
        case .junit:
            let words = original.split(separator: " ").map { ($0 as NSString).lastPathComponent }
            let ids = fs.map { ($0.group.map { $0 + "." } ?? "") + $0.name }
            if words.contains(where: { $0.hasPrefix("mvn") }) {
                let tool = words.first(where: { $0.hasPrefix("mvn") }) == "mvnw" ? "./mvnw" : "mvn"
                return tool + " test -Dtest=" + q(fs.map { ($0.group?.split(separator: ".").last.map(String.init) ?? "") + "#" + $0.name }.joined(separator: ","))
            }
            let tool = words.contains("gradlew") ? "./gradlew" : "gradle"
            return tool + " test " + ids.map { "--tests " + q($0) }.joined(separator: " ")
        }
    }

    /// The start of `command` up to and including the first word in `through`
    /// ("uv run pytest -x tests" → "uv run pytest"), else `fallback`.
    static func prefix(_ command: String, through: [String], fallback: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        guard let i = words.firstIndex(where: { through.contains(($0 as NSString).lastPathComponent) }) else { return fallback }
        // Keep `cargo test`, not `cargo test some_filter`.
        return words[...i].joined(separator: " ")
    }

    /// Single quotes for anything that isn't plainly safe ("a b" → 'a b').
    static func quote(_ s: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func regexEscape(_ s: String) -> String {
        let special = Set("\\^$.|?*+()[]{}")
        return String(s.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    // MARK: Helpers

    static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        return s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }
}
