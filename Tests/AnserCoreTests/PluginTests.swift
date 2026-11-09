import Foundation
import XCTest
@testable import AnserCore

final class PluginTests: XCTestCase {
    func testLoadManifestsAndErrors() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anser-plugins-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/good", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/bad", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/empty", withIntermediateDirectories: true)
        try #"{"name":"Good","chips":[{"id":"a","script":"echo hi","interval":30}],"actions":[{"title":"Do","run":"ls"}]}"#
            .write(toFile: dir + "/good/plugin.json", atomically: true, encoding: .utf8)
        try #"{"chips":[]}"#.write(toFile: dir + "/bad/plugin.json", atomically: true, encoding: .utf8)
        let (plugins, errors) = PluginRegistry.load(from: dir)
        XCTAssertEqual(plugins.map(\.id), ["good"])
        XCTAssertEqual(plugins.first?.manifest.summary, "1 chip · 1 action")
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("name"), errors[0])
    }

    func testTemplateIsValid() throws {
        let m = try JSONDecoder().decode(PluginManifest.self, from: Data(PluginTemplate.manifest.utf8))
        XCTAssertEqual(m.chips?.count, 1)
        XCTAssertEqual(m.actions?.count, 2)
        XCTAssertNotNil(m.hooks?.commandFinished)
    }

    func testScriptsStayInTheirFolder() {
        XCTAssertEqual(PluginRegistry.argv(for: "./x.sh", in: "/p/one"), ["/p/one/x.sh"])
        XCTAssertEqual(PluginRegistry.argv(for: "./../../etc/evil", in: "/p/one"), ["/bin/sh", "-c", "./../../etc/evil"])
        XCTAssertEqual(PluginRegistry.argv(for: "git log -1", in: "/p/one"), ["/bin/sh", "-c", "git log -1"])
    }

    func testWhen() {
        let files: Set<String> = ["/w/proj/package.json"]
        XCTAssertTrue(PluginRegistry.applies(nil, cwd: "/x"))
        XCTAssertTrue(PluginRegistry.applies(["package.json"], cwd: "/w/proj/src", exists: { files.contains($0) }))
        XCTAssertFalse(PluginRegistry.applies(["Cargo.toml"], cwd: "/w/proj", exists: { files.contains($0) }))
    }

    func testOutputs() {
        XCTAssertEqual(PluginOutput.chip("v20.1.0\nmore"), PluginOutput.Chip(text: "v20.1.0"))
        XCTAssertNil(PluginOutput.chip("  \n"))
        let c = PluginOutput.chip(#"{"text":"3 todos","color":"yellow","run":"rg TODO"}"#)
        XCTAssertEqual(c?.text, "3 todos")
        XCTAssertEqual(c?.run, "rg TODO")
        XCTAssertNil(PluginOutput.chip(#"{"color":"red"}"#))
        XCTAssertEqual(PluginOutput.rows("a\tb\tls -la\nc").map(\.text), ["a", "c"])
        XCTAssertEqual(PluginOutput.rows("a\tb\tls -la").first?.run, "ls -la")
        XCTAssertEqual(PluginOutput.rows(#"[{"text":"x","open":"https://example.com"},{"detail":"no text"}]"#).count, 1)
        XCTAssertNotNil(PluginOutput.safeToOpen("https://example.com"))
        XCTAssertNil(PluginOutput.safeToOpen("javascript:alert(1)"))
        XCTAssertNil(PluginOutput.safeToOpen("file-but-relative"))
    }
}
