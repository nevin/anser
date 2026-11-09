import XCTest
@testable import AnserCore

final class ForegroundJobTests: XCTestCase {
    func testProcessInfoHelpers() {
        XCTAssertTrue(ForegroundJob.pids(inGroup: getpgrp()).contains(getpid()))
        XCTAssertNotNil(ForegroundJob.name(getpid()))
        XCTAssertNil(ForegroundJob.of(shellPID: 0))
        XCTAssertNil(ForegroundJob.of(shellPID: 1))
    }

    func testNeverSignalsItsOwnGroup() {
        let own = ForegroundJob.Info(pgid: getpgrp(), names: ["xctest"])
        XCTAssertFalse(ForegroundJob.send(0, to: own))
        XCTAssertFalse(ForegroundJob.send(0, to: .init(pgid: 1, names: ["launchd"])))
    }

    func testPagers() {
        XCTAssertTrue(ForegroundJob.isPager(.init(pgid: 5, names: ["git", "less"])))
        XCTAssertFalse(ForegroundJob.isPager(.init(pgid: 5, names: ["git"])))
    }
}
