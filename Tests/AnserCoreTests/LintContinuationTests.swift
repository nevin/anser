import XCTest
@testable import AnserCore

final class LintContinuationTests: XCTestCase {
    /// A command split over lines with a trailing backslash is one command, not several.
    func testBackslashNewlineContinuesTheCommand() {
        let cmd = "docker run --rm \\\n  -v \"$PWD\":/app \\\n  -w /app \\\n  -e NODE_ENV=production \\\n  node:22 npm run build"
        let issues = CommandLint.check(cmd, isKnown: { $0 == "docker" })
        XCTAssertEqual(issues.map(\.message), [])
    }
}
