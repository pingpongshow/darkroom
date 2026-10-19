import XCTest

/// Presets in Develop: hover preview, apply, Amount, save and delete a user preset. Resets before leaving,
/// so nothing is uploaded.
@MainActor
final class PresetUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testPresetsPanelApplyAmountSaveDelete() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        // A JPEG via file-name search, then Develop.
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
        XCTAssertTrue(any(app, "presets-panel").exists)

        // Open the Color folder, hover and apply "Golden Hour".
        any(app, "preset-folder-Color").click()
        let golden = any(app, "preset-Golden Hour")
        XCTAssertTrue(golden.waitForExistence(timeout: 5))
        golden.hover()
        sleep(2)
        UITestSupport.screenshot("m4b-1-hover", in: self)
        golden.click()
        let amount = app.sliders["preset-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5), "Amount slider appears after applying")
        amount.adjust(toNormalizedSliderPosition: 0.9)
        sleep(2)
        UITestSupport.screenshot("m4b-2-applied-amount", in: self)

        // Save as a preset, then delete it.
        any(app, "presets-menu").click()
        app.menuItems["Save Preset…"].click()
        let name = app.textFields["preset-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("UITest Look")
        app.buttons["preset-create"].click()
        any(app, "preset-folder-My Presets").click()
        let mine = any(app, "preset-UITest Look")
        XCTAssertTrue(mine.waitForExistence(timeout: 5))
        UITestSupport.screenshot("m4b-3-saved", in: self)
        mine.rightClick()
        let delete = app.menuItems.matching(NSPredicate(format: "title == 'Delete'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(delete).click()
        XCTAssertFalse(mine.waitForExistence(timeout: 3))

        // Reset so leaving Develop uploads nothing.
        app.buttons["develop-cancel"].click()   // Cancel discards the edits; nothing is uploaded
        sleep(1)
        app.typeKey(.escape, modifierFlags: [])
    }
}
