import XCTest
@testable import AnserCore

final class KeyTipsTests: XCTestCase {
    /// Each shortcut's tip retires after a few uses; "always" keeps them all.
    func testTipsRetireOnceLearned() {
        var e = TipEngine()
        XCTAssertEqual(e.keyTipsToShow(all: false).count, TipEngine.keyTips.count)
        for _ in 0..<TipEngine.learnedAfter { e.usedKey("⌘R") }
        XCTAssertFalse(e.keyTipsToShow(all: false).contains { $0.key == "⌘R" })
        XCTAssertEqual(e.keyTipsToShow(all: true).count, TipEngine.keyTips.count)
        for k in TipEngine.keyTips { for _ in 0..<TipEngine.learnedAfter { e.usedKey(k.key) } }
        XCTAssertTrue(e.keyTipsToShow(all: false).isEmpty)
    }

    func testDefaultSeparatorIsTime() throws {
        XCTAssertEqual(AnserConfig().commandSeparator, "time")
        let c = try JSONDecoder().decode(AnserConfig.self, from: Data(#"{"commandSeparator":"dotted"}"#.utf8))
        XCTAssertEqual(c.commandSeparator, "dotted")
    }
}
