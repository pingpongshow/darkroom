import XCTest

/// M8: pick / reject / unflag with undo, compare and survey modes, filter bar, export, cheat sheet.
@MainActor
final class WorkflowUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func status(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 60) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: app.staticTexts["status-message"])
        waitForExpectations(timeout: timeout)
    }

    func testCullingCompareSurveyAndExport() throws {
        let exportDir = FileManager.default.temporaryDirectory.appending(path: "darkroom-export-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exportDir) }
        let app = UITestSupport.launch(extraEnvironment: ["DARKROOM_TEST_EXPORT": exportDir.path])
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Flags.
        cells(app).firstMatch.click()
        app.typeKey("p", modifierFlags: [])
        status(app, "Pick")
        app.typeKey("x", modifierFlags: [])
        status(app, "Reject")
        app.typeKey("z", modifierFlags: .command)
        status(app, "Undo")
        app.typeKey("u", modifierFlags: [])
        status(app, "Unflag")

        // Compare two photos, then survey.
        cells(app).firstMatch.click()
        XCUIElement.perform(withKeyModifiers: .command) { cells(app).element(boundBy: 1).click() }
        app.typeKey("c", modifierFlags: [])
        XCTAssertTrue(any(app, "compare-view").waitForExistence(timeout: 10))
        UITestSupport.screenshot("m8-1-compare", in: self)
        app.typeKey("g", modifierFlags: [])
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: [])
        XCTAssertTrue(any(app, "survey-view").waitForExistence(timeout: 10))
        UITestSupport.screenshot("m8-2-survey", in: self)
        app.typeKey("g", modifierFlags: [])

        // Filter bar.
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 10))
        app.typeKey("\\", modifierFlags: [])
        XCTAssertTrue(any(app, "filter-bar").waitForExistence(timeout: 5))
        app.typeKey("\\", modifierFlags: [])

        // Export one photo: ⌘-click the second photo out of the earlier two-photo selection.
        XCUIElement.perform(withKeyModifiers: .command) { cells(app).element(boundBy: 1).click() }
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(any(app, "export-confirm").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Export 1 Item"].exists, "Exactly one photo selected")
        UITestSupport.screenshot("m8-3-export", in: self)
        any(app, "export-confirm").click()
        status(app, "Exported 1 item", timeout: 120)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        XCTAssertEqual(files.count, 1, "One exported file")

        // Keyboard shortcut cheat sheet.
        app.typeKey("/", modifierFlags: .command)
        XCTAssertTrue(any(app, "cheat-sheet").waitForExistence(timeout: 5))
        UITestSupport.screenshot("m8-4-shortcuts", in: self)
        app.typeKey(.escape, modifierFlags: [])
    }
}
