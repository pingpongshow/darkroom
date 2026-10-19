import XCTest

/// Develop: edit, before/after, B&W + undo, crop, save a version, then revert (leaves the library as seeded).
@MainActor
final class DevelopUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func status(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: app.staticTexts["status-message"])
        waitForExpectations(timeout: timeout)
    }

    func testDevelopEditSaveAndRevert() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Find a JPEG by file name.
        app.buttons["search-filters"].click()
        let textMode = app.popUpButtons["filter-text-mode"]
        XCTAssertTrue(textMode.waitForExistence(timeout: 5))
        textMode.click(); app.menuItems["File name"].click()
        app.typeKey(.escape, modifierFlags: [])
        app.textFields["search-field"].click()
        app.textFields["search-field"].typeText(".jpg\r")
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        cells(app).firstMatch.click()

        // D opens Develop.
        app.typeKey("d", modifierFlags: [])
        let preview = any(app, "develop-preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 60), "Original downloads and renders")
        sleep(2)
        UITestSupport.screenshot("m4-1-develop", in: self)

        // Exposure and auto tone.
        let exposure = app.sliders["slider-Exposure"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        exposure.adjust(toNormalizedSliderPosition: 0.58)
        any(app, "slider-Vibrance").adjust(toNormalizedSliderPosition: 0.7)
        sleep(2)
        UITestSupport.screenshot("m4-2-adjusted", in: self)

        // Before/after.
        app.typeKey("\\", modifierFlags: [])
        sleep(2)
        UITestSupport.screenshot("m4-3-before", in: self)
        app.typeKey("\\", modifierFlags: [])

        // B&W (V), then undo (⌘Z).
        app.typeKey("v", modifierFlags: [])
        sleep(2)
        UITestSupport.screenshot("m4-4-bw", in: self)
        app.typeKey("z", modifierFlags: .command)
        sleep(2)

        // Crop tool (R): straighten a little, apply.
        app.typeKey("r", modifierFlags: [])
        XCTAssertTrue(any(app, "crop-rect").waitForExistence(timeout: 10))
        app.sliders["crop-straighten"].adjust(toNormalizedSliderPosition: 0.53)
        sleep(2)
        UITestSupport.screenshot("m4-5-crop", in: self)
        app.buttons["crop-apply"].click()
        sleep(2)

        // Reset returns to the saved state (here the original) and stays; ⌘Z brings the edits back.
        XCTAssertTrue(any(app, "develop-unsaved").exists, "Unsaved changes are shown")
        app.buttons["develop-reset"].click()
        XCTAssertFalse(any(app, "develop-unsaved").waitForExistence(timeout: 2), "Reset clears the changes")
        XCTAssertTrue(preview.exists, "Still in the editor")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(any(app, "develop-unsaved").waitForExistence(timeout: 3), "Undo brings them back")

        // Esc with unsaved changes asks; Keep Editing stays.
        app.typeKey(.escape, modifierFlags: [])
        let keep = app.sheets.buttons["Keep Editing"]   // (the Touch Bar has a copy of the button too)
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Leaving with unsaved changes asks first")
        keep.click()
        XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 1), "Dialog closed")
        XCTAssertTrue(preview.exists)

        // Save saves a stacked version and closes the editor.
        app.buttons["develop-save"].click()
        status(app, "Saved edited version", timeout: 120)
        sleep(2)
        UITestSupport.screenshot("m4-6-saved", in: self)

        // Revert to original.
        app.typeKey("d", modifierFlags: [])
        XCTAssertTrue(preview.waitForExistence(timeout: 60))
        sleep(2)
        any(app, "develop-more").click()
        app.menuItems["Revert to Original"].click()
        status(app, "Reverted", timeout: 60)
    }
}
