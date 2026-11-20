import XCTest
@testable import AnserCore

final class RelayFastPathTests: XCTestCase {
    func testOutputWithoutPicturesPassesStraightThrough() {
        var f = InlineImageFilter()
        let colored = Data("line \u{1b}[32mok\u{1b}[0m\n\u{1b}]0;title\u{07}more".utf8)
        XCTAssertFalse(InlineImageFilter.mayHoldImage(colored))
        XCTAssertEqual(f.feed(colored), colored)
        // A picture's start, whole or cut off at the end of a read, takes the full path.
        XCTAssertTrue(InlineImageFilter.mayHoldImage(Data("x\u{1b}]1337;File=inline=1:AAAA\u{07}".utf8)))
        XCTAssertTrue(InlineImageFilter.mayHoldImage(Data("text \u{1b}]13".utf8)))
        XCTAssertTrue(InlineImageFilter.mayHoldImage(Data("text \u{1b}".utf8)))
        XCTAssertFalse(InlineImageFilter.mayHoldImage(Data("text \u{1b}]1338".utf8)))
    }

    func testFindsTheLastAlternateScreenSwitch() {
        XCTAssertNil(ReplayBuffer.lastAlternateSwitch(in: Data("plain \u{1b}[31mred\u{1b}[0m \u{1b}[?25l".utf8)))
        XCTAssertEqual(ReplayBuffer.lastAlternateSwitch(in: Data("a\u{1b}[?1049hvim".utf8)), true)
        XCTAssertEqual(ReplayBuffer.lastAlternateSwitch(in: Data("\u{1b}[?1049h…\u{1b}[?1049l$ ".utf8)), false)
        XCTAssertEqual(ReplayBuffer.lastAlternateSwitch(in: Data("\u{1b}[?47l x \u{1b}[?1047h".utf8)), true)
        var r = ReplayBuffer(limit: 1 << 16)
        r.append(Data("before \u{1b}[?104".utf8))
        r.append(Data("9h in vim".utf8))
        XCTAssertTrue(r.alternateScreen)
        r.append(Data("\u{1b}[?1049l".utf8))
        XCTAssertFalse(r.alternateScreen)
    }
}
