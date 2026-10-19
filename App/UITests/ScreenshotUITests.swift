import XCTest

/// README screenshots from the demo account (generated landscapes, no personal photos).
/// Runs only when asked: TEST_RUNNER_DARKROOM_SCREENSHOTS=1 with demo credentials as the test credentials.
@MainActor
final class ScreenshotUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testReadmeScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DARKROOM_SCREENSHOTS"] == "1", "Screenshots only on request")
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 30))
        sleep(4)   // thumbnails

        // 1. Grid with the date bar and info panel (smaller thumbnails).
        cells(app).element(boundBy: 2).click()
        for _ in 0..<4 { app.typeKey("-", modifierFlags: .command); usleep(300_000) }
        sleep(3)
        UITestSupport.screenshot("readme-1-grid", in: self)

        // 2. Single photo with the info panel.
        cells(app).element(boundBy: 2).doubleClick()
        XCTAssertTrue(any(app, "loupe").waitForExistence(timeout: 10))
        sleep(4)
        UITestSupport.screenshot("readme-2-photo", in: self)

        // 3. Editor with a few adjustments (cancelled afterwards, nothing saved).
        any(app, "edit-photo").click()
        XCTAssertTrue(any(app, "develop-preview").waitForExistence(timeout: 60))
        app.sliders["slider-Vibrance"].adjust(toNormalizedSliderPosition: 0.68)
        app.sliders["slider-Contrast"].adjust(toNormalizedSliderPosition: 0.6)
        sleep(4)
        UITestSupport.screenshot("readme-3-editor", in: self)
        app.buttons["develop-cancel"].click()
        sleep(1)
        app.typeKey("g", modifierFlags: [])

        // 4. Albums, 5. Map, 6. Explore.
        UITestSupport.go(app, "Albums")
        sleep(4)
        UITestSupport.screenshot("readme-4-albums", in: self)
        UITestSupport.go(app, "Map")
        sleep(8)
        UITestSupport.screenshot("readme-5-map", in: self)
        UITestSupport.go(app, "Explore")
        sleep(5)
        UITestSupport.screenshot("readme-6-explore", in: self)
    }
}
