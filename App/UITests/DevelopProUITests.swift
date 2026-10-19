import XCTest

/// Upright, lens, calibration, HDR and the merge sheet. Nothing is uploaded (reset / cancel).
@MainActor
final class DevelopProUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testUprightLensHDRAndMergeSheet() throws {
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

        // Merge sheet for two photos (cancelled).
        cells(app).element(boundBy: 0).click()
        XCUIElement.perform(withKeyModifiers: .shift) { cells(app).element(boundBy: 1).click() }
        sleep(1)
        app.typeKey("m", modifierFlags: .control)
        let preview = any(app, "merge-preview")
        let failed = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'overlap' OR value CONTAINS 'aligned'")).firstMatch
        let deadline = Date().addingTimeInterval(90)
        while !preview.exists && !failed.exists && Date() < deadline { usleep(500_000) }
        XCTAssertTrue(preview.exists || failed.exists, "Merge sheet previews or explains")
        UITestSupport.screenshot("m4c2-1-merge", in: self)
        app.typeKey(.escape, modifierFlags: [])

        // Develop: Upright, lens, calibration, HDR.
        cells(app).firstMatch.click()
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(any(app, "develop-preview").waitForExistence(timeout: 60))
        any(app, "panel-Transform").click()
        any(app, "upright-Level").click()
        let status = app.staticTexts["status-message"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Upright' OR value CONTAINS 'horizon'"), evaluatedWith: status)
        waitForExpectations(timeout: 30)
        any(app, "panel-Lens Corrections").click()
        app.sliders["slider-Vignetting"].adjust(toNormalizedSliderPosition: 0.8)
        any(app, "panel-Profile & RAW").click()
        let hdr = app.checkBoxes["develop-hdr"]
        XCTAssertTrue(hdr.waitForExistence(timeout: 5))
        hdr.click()
        sleep(3)
        UITestSupport.screenshot("m4c2-2-develop-pro", in: self)
        any(app, "develop-more").click()
        app.menuItems["Reset All"].click()
        sleep(1)
        app.typeKey(.escape, modifierFlags: [])
    }
}
