import XCTest
@testable import AnserCore

final class CommitAndVenvTests: XCTestCase {
    func testCommitCommand() {
        XCTAssertEqual(GitCommit.command(.init(message: "Fix the login redirect")), "git commit -m 'Fix the login redirect'")
        XCTAssertEqual(GitCommit.command(.init(message: "  It's done\n", stageAll: true, push: true)),
                       "git add -A && git commit -m 'It'\\''s done' && git push")
        XCTAssertEqual(GitCommit.command(.init(message: "New page", push: false, hasUpstream: false, openPullRequest: true)),
                       "git commit -m 'New page' && git push -u origin HEAD && gh pr create --fill --web")
        // A message can't run anything.
        XCTAssertEqual(GitCommit.command(.init(message: "$(rm -rf ~) `x`")), "git commit -m '$(rm -rf ~) `x`'")
    }

    func testAICommitMessageCleanup() {
        XCTAssertEqual(AIHelp.oneLine("Add Node switching per project\n\nMore detail."), "Add Node switching per project")
        XCTAssertEqual(AIHelp.oneLine("```\n\"Fix pip fix label\"\n```"), "Fix pip fix label")
        XCTAssertEqual(AIHelp.oneLine("Commit message: Update the README"), "Update the README")
        XCTAssertEqual(AIHelp.oneLine("**Speed up new tabs**"), "Speed up new tabs")
    }

    func testFindVenv() {
        let have: Set<String> = ["/h/app/.venv/bin/activate", "/h/app/.git", "/h/other/venv/bin/activate"]
        let exists: (String) -> Bool = { have.contains($0) }
        XCTAssertEqual(ProjectEnv.findVenv(from: "/h/app/src/pkg", home: "/h", exists: exists), "/h/app/.venv")
        XCTAssertEqual(ProjectEnv.findVenv(from: "/h/other", home: "/h", exists: exists), "/h/other/venv")
        XCTAssertNil(ProjectEnv.findVenv(from: "/h/none", home: "/h", exists: exists))
        XCTAssertNil(ProjectEnv.findVenv(from: "/h", home: "/h", exists: exists))
    }
}
