import XCTest

/// Edit in Preview: a session appears (Done / Cancel); cancelled, so nothing is uploaded.
@MainActor
final class EditInUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }

    func testEditInPreviewShowsSession() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        let photo = cells(app).matching(NSPredicate(format: "label == 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.rightClick()
        let editIn = app.menuItems.matching(NSPredicate(format: "title == 'Edit in'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(editIn).hover()
        let preview = app.menuItems.matching(NSPredicate(format: "title == 'Preview'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(preview, "Preview is listed").click()
        let bar = app.descendants(matching: .any)["edit-sessions"]
        XCTAssertTrue(bar.waitForExistence(timeout: 30), "Editing session shown")
        app.activate()
        sleep(2)
        UITestSupport.screenshot("m6-1-edit-in", in: self)
        app.buttons["edit-in-cancel"].firstMatch.click()
        XCTAssertFalse(bar.waitForExistence(timeout: 3))
        // Close Preview's window again.
        let previewApp = XCUIApplication(bundleIdentifier: "com.apple.Preview")
        if previewApp.state == .runningForeground || previewApp.state == .runningBackground { previewApp.terminate() }
    }
}
