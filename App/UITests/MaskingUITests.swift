import XCTest

/// Masks and retouch in Develop. Resets before leaving, so nothing is uploaded.
@MainActor
final class MaskingUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testGradientSubjectBrushAndSpot() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        app.buttons["search-filters"].click()
        let textMode = app.popUpButtons["filter-text-mode"]
        XCTAssertTrue(textMode.waitForExistence(timeout: 5))
        textMode.click(); app.menuItems["File name"].click()
        app.typeKey(.escape, modifierFlags: [])
        app.textFields["search-field"].click()
        app.textFields["search-field"].typeText(".jpg\r")
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        cells(app).firstMatch.click()
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(any(app, "develop-preview").waitForExistence(timeout: 60))

        // Linear gradient (M), darken it.
        app.typeKey("m", modifierFlags: [])
        any(app, "panel-Masks").click()
        let exposure = app.sliders["mask-slider-Exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        exposure.adjust(toNormalizedSliderPosition: 0.3)
        sleep(3)
        UITestSupport.screenshot("m4c-1-linear-mask", in: self)

        // Select Subject and brighten it.
        any(app, "mask-add").click()
        app.menuItems["Select Subject"].click()
        app.sliders["mask-slider-Exposure"].adjust(toNormalizedSliderPosition: 0.62)
        sleep(5)
        UITestSupport.screenshot("m4c-2-subject-mask", in: self)

        // Brush (K) and paint a stroke.
        app.typeKey("k", modifierFlags: [])
        let canvas = any(app, "mask-canvas")
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
        from.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35)))
        app.sliders["mask-slider-Saturation"].adjust(toNormalizedSliderPosition: 0.0)
        sleep(3)
        UITestSupport.screenshot("m4c-3-brush", in: self)

        // Spot removal (Q): click to add a heal spot.
        app.typeKey("q", modifierFlags: [])
        any(app, "panel-Retouch").click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).click()
        sleep(3)
        UITestSupport.screenshot("m4c-4-spot", in: self)
        XCTAssertTrue(app.staticTexts["1 spot"].waitForExistence(timeout: 5))

        // Reset so leaving uploads nothing.
        app.typeKey(.escape, modifierFlags: [])
        any(app, "develop-more").click()
        app.menuItems["Reset All"].click()
        sleep(1)
        app.typeKey(.escape, modifierFlags: [])
    }
}
