import XCTest

/// Video rotation (lossless version, then rotated back = reverted), Develop declines videos, Make Still + undo.
@MainActor
final class RotateUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func status(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 120) {
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: app.staticTexts["status-message"])
        waitForExpectations(timeout: timeout)
    }

    func testRotateVideoAndMakeStill() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Videos (Explore ▸ Videos).
        UITestSupport.go(app, "Explore")
        any(app, "explore-Videos").click()
        let video = cells(app).matching(NSPredicate(format: "label == 'Video'")).firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 20))
        video.click()
        app.typeKey("d", modifierFlags: [])
        status(app, "Videos can be rotated", timeout: 10)

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])
        status(app, "Rotated 1 item")
        sleep(2)
        UITestSupport.screenshot("m5-1-video-rotated", in: self)
        // Rotating back to 0° reverts to the original (the version goes to Immich's trash).
        let rotated = cells(app).matching(NSPredicate(format: "label == 'Video'")).firstMatch
        rotated.click()
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        expectation(for: NSPredicate(format: "value CONTAINS 'Rotated 1 item' OR value CONTAINS 'Reverted'"), evaluatedWith: app.staticTexts["status-message"])
        waitForExpectations(timeout: 120)

        // Make Still on a Live Photo, then undo.
        UITestSupport.go(app, "Photos")
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        cells(app).firstMatch.doubleClick()
        let play = any(app, "play-live")
        var steps = 0
        while !play.waitForExistence(timeout: 1.5) && steps < 30 { app.typeKey(.rightArrow, modifierFlags: []); steps += 1 }
        XCTAssertTrue(play.exists, "Found a Live Photo")
        any(app, "loupe").rightClick()
        let item = app.menuItems.matching(NSPredicate(format: "title == 'Make Still'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(item).click()
        status(app, "Make Still", timeout: 20)
        app.typeKey("z", modifierFlags: .command)
        status(app, "Undo", timeout: 20)
    }
}
