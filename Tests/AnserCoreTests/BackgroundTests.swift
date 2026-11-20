import XCTest
@testable import AnserCore

final class BackgroundTests: XCTestCase {
    func testOpacityAndPicture() {
        var a = AnserConfig.Appearance()
        XCTAssertNil(a.effectiveBackgroundOpacity, "solid by default")
        XCTAssertFalse(a.ghosttyLines.contains { $0.hasPrefix("background-opacity") })

        a.backgroundOpacity = 0.05
        XCTAssertEqual(a.effectiveBackgroundOpacity, 0.1, "never fully invisible")
        XCTAssertTrue(a.ghosttyLines.contains("background-opacity = 0.1"))

        a.backgroundOpacity = nil
        a.backgroundImage = "  "
        XCTAssertFalse(a.hasBackgroundImage)
        a.backgroundImage = "~/Pictures/sky.jpg"
        XCTAssertEqual(a.effectiveBackgroundOpacity, 0.7, "a picture needs the colour see-through")
        a.backgroundOpacity = 0.4
        XCTAssertTrue(a.ghosttyLines.contains("background-opacity = 0.4"))

        XCTAssertEqual(a.imageFit, "fill")
        a.backgroundImageFit = "fit"
        XCTAssertEqual(a.imageFit, "fit")
        a.backgroundImageFit = "tile"
        XCTAssertEqual(a.imageFit, "fill", "unknown values fall back")
    }

    func testDecodesFromConfigJSON() throws {
        let json = #"{"backgroundImage": "/tmp/bg.png", "backgroundImageFit": "center", "backgroundOpacity": 0.5}"#
        let a = try JSONDecoder().decode(AnserConfig.Appearance.self, from: Data(json.utf8))
        XCTAssertTrue(a.hasBackgroundImage)
        XCTAssertEqual(a.imageFit, "center")
        XCTAssertEqual(a.effectiveBackgroundOpacity, 0.5)
    }
}
