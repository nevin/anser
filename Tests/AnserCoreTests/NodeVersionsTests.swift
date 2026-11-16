import XCTest
@testable import AnserCore

final class NodeVersionsTests: XCTestCase {
    typealias V = NodeVersions.Version

    private func inst(_ versions: [String], dir: String = "/n") -> [NodeVersions.Installed] {
        versions.compactMap(V.init).sorted(by: >).map { NodeVersions.Installed(version: $0, bin: "\(dir)/v\($0)/bin") }
    }

    func testVersionParsing() {
        XCTAssertEqual(V("v22.23.3"), V(22, 23, 3))
        XCTAssertEqual(V("22"), V(22))
        XCTAssertEqual(V("18.2"), V(18, 2))
        XCTAssertEqual(V("20.0.0-beta"), V(20))
        XCTAssertNil(V("lts/iron"))
        XCTAssertNil(V("node"))
        XCTAssertTrue(V(22, 1) < V(22, 10))
    }

    func testRanges() {
        let v22 = V(22, 23, 3), v26 = V(26, 13, 0), v18 = V(18, 2, 1)
        XCTAssertTrue(NodeVersions.satisfies(v22, ">=22"))
        XCTAssertTrue(NodeVersions.satisfies(v22, ">= 22"))
        XCTAssertFalse(NodeVersions.satisfies(v22, ">=24"))
        XCTAssertTrue(NodeVersions.satisfies(v22, ">=22.2"))
        XCTAssertTrue(NodeVersions.satisfies(v22, "^22.1"))
        XCTAssertFalse(NodeVersions.satisfies(v26, "^22"))
        XCTAssertTrue(NodeVersions.satisfies(v26, "^20 || ^22 || >=24"))
        XCTAssertTrue(NodeVersions.satisfies(v18, "~18.2"))
        XCTAssertFalse(NodeVersions.satisfies(V(18, 3), "~18.2"))
        XCTAssertTrue(NodeVersions.satisfies(v18, "18.x"))
        XCTAssertTrue(NodeVersions.satisfies(v18, ">=16 <20"))
        XCTAssertFalse(NodeVersions.satisfies(v22, ">=16 <20"))
        XCTAssertTrue(NodeVersions.satisfies(V(20, 5), "18 - 20"))
        XCTAssertFalse(NodeVersions.satisfies(V(21), "18 - 20"))
        XCTAssertTrue(NodeVersions.satisfies(V(19), ">18"))
        XCTAssertFalse(NodeVersions.satisfies(V(18, 9), ">18"))
        XCTAssertTrue(NodeVersions.satisfies(V(20, 9), "<=20"))
        XCTAssertTrue(NodeVersions.satisfies(v22, "*"))
    }

    func testDefaultStaysWhenItFits() {
        let all = inst(["22.23.3", "23.11.0", "26.13.0"])
        let current = all.first { $0.version.major == 26 }
        let req = NodeVersions.Requirement(kind: .range(">=24"), source: "package.json", root: "/p")
        XCTAssertEqual(NodeVersions.choose(req, installed: all, current: current, nvmDir: "/nvm", read: { _ in nil }), .use(current!))
    }

    func testPicksNewestThatFits() {
        let all = inst(["22.1.0", "22.23.3", "23.11.0", "26.13.0"])
        let current = all.first { $0.version.major == 26 }
        let pinned = NodeVersions.Requirement(kind: .pinned("22"), source: ".nvmrc", root: "/p")
        guard case .use(let a) = NodeVersions.choose(pinned, installed: all, current: current, nvmDir: "/nvm", read: { _ in nil }) else { return XCTFail() }
        XCTAssertEqual(a.version, V(22, 23, 3))
        let range = NodeVersions.Requirement(kind: .range("^22 || ^23"), source: "package.json", root: "/p")
        guard case .use(let b) = NodeVersions.choose(range, installed: all, current: current, nvmDir: "/nvm", read: { _ in nil }) else { return XCTFail() }
        XCTAssertEqual(b.version, V(23, 11, 0))
    }

    func testMissingSaysWhatToInstall() {
        let all = inst(["22.23.3", "23.11.0"])
        let req = NodeVersions.Requirement(kind: .range(">=24"), source: "package.json", root: "/p")
        XCTAssertEqual(NodeVersions.choose(req, installed: all, current: all.first, nvmDir: "/nvm", read: { _ in nil }), .missing(install: "24"))
        let gt = NodeVersions.Requirement(kind: .range(">23"), source: "package.json", root: "/p")
        XCTAssertEqual(NodeVersions.choose(gt, installed: all, current: all.first, nvmDir: "/nvm", read: { _ in nil }), .missing(install: "24"))
        let pinned = NodeVersions.Requirement(kind: .pinned("v20.11"), source: ".nvmrc", root: "/p")
        XCTAssertEqual(NodeVersions.choose(pinned, installed: all, current: nil, nvmDir: "/nvm", read: { _ in nil }), .missing(install: "20.11"))
    }

    func testAliases() {
        let all = inst(["20.19.0", "22.23.3", "23.11.0"])
        let files = ["/nvm/alias/lts/iron": "v20.19.0", "/nvm/alias/lts/*": "lts/jod", "/nvm/alias/lts/jod": "v22.23.3", "/nvm/alias/default": "22"]
        let read: (String) -> String? = { files[$0] }
        let iron = NodeVersions.Requirement(kind: .pinned("lts/iron"), source: ".nvmrc", root: "/p")
        guard case .use(let a) = NodeVersions.choose(iron, installed: all, current: nil, nvmDir: "/nvm", read: read) else { return XCTFail() }
        XCTAssertEqual(a.version.major, 20)
        let newest = NodeVersions.Requirement(kind: .pinned("node"), source: ".nvmrc", root: "/p")
        guard case .use(let b) = NodeVersions.choose(newest, installed: all, current: nil, nvmDir: "/nvm", read: read) else { return XCTFail() }
        XCTAssertEqual(b.version.major, 23)
        XCTAssertEqual(NodeVersions.defaultVersion(nvmDir: "/nvm", installed: all, read: read)?.version, V(22, 23, 3))
        XCTAssertEqual(NodeVersions.defaultVersion(nvmDir: "/nvm", installed: all, read: { _ in nil })?.version, V(23, 11, 0))
    }

    func testRequirementLookup() {
        let files = [
            "/h/app/.nvmrc": "22\n",
            "/h/web/package.json": #"{"name":"web","engines":{"node":">=24"}}"#,
            "/h/plain/package.json": #"{"name":"plain"}"#,
        ]
        let read: (String) -> String? = { files[$0] }
        let exists: (String) -> Bool = { files[$0] != nil }
        XCTAssertEqual(NodeVersions.requirement(from: "/h/app/src", home: "/h", exists: exists, read: read),
                       .init(kind: .pinned("22"), source: ".nvmrc", root: "/h/app"))
        XCTAssertEqual(NodeVersions.requirement(from: "/h/web", home: "/h", exists: exists, read: read)?.kind, .range(">=24"))
        XCTAssertNil(NodeVersions.requirement(from: "/h/plain", home: "/h", exists: exists, read: read))
        XCTAssertNil(NodeVersions.requirement(from: "/h", home: "/h", exists: exists, read: read))
    }

    func testInstalledListsNvmAndFnm() {
        let dirs: [String: [String]] = ["/nvm/versions/node": ["v22.1.0", "v26.0.0", ".DS_Store"], "/fnm/node-versions": ["v20.5.0", "v22.1.0"]]
        let exes: Set<String> = ["/nvm/versions/node/v22.1.0/bin/node", "/nvm/versions/node/v26.0.0/bin/node",
                                 "/fnm/node-versions/v20.5.0/installation/bin/node", "/fnm/node-versions/v22.1.0/installation/bin/node"]
        let found = NodeVersions.installed(folders: ["/nvm/versions/node", "/fnm/node-versions"], list: { dirs[$0] }, isExecutable: { exes.contains($0) })
        XCTAssertEqual(found.map(\.version.major), [26, 22, 20])
        XCTAssertEqual(found[1].bin, "/nvm/versions/node/v22.1.0/bin")
        XCTAssertEqual(found[2].bin, "/fnm/node-versions/v20.5.0/installation/bin")
    }

    func testPathSwap() {
        let folders = ["/nvm/versions/node"]
        let path = ["/nvm/versions/node/v26.0.0/bin", "/opt/homebrew/bin", "/usr/bin"]
        XCTAssertEqual(NodeVersions.activeBin(in: path, folders: folders), "/nvm/versions/node/v26.0.0/bin")
        XCTAssertEqual(NodeVersions.path(path, using: "/nvm/versions/node/v22.1.0/bin", folders: folders),
                       ["/nvm/versions/node/v22.1.0/bin", "/opt/homebrew/bin", "/usr/bin"])
    }
}
