import XCTest

@MainActor
final class LibraryUITests: XCTestCase {
    func testGridLoupeInfoAndNavigation() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)

        // Grid shows real thumbnails for the seeded library.
        let grid = app.descendants(matching: .any)["photo-grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20), "Photo grid should appear")
        let cells = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 20), "Thumbnails should appear")
        sleep(3) // let thumbnails finish loading for the screenshot
        UITestSupport.screenshot("1-grid", in: self)
        XCTAssertGreaterThanOrEqual(cells.count, 1)
        let count = app.staticTexts["item-count"]
        XCTAssertTrue((count.value as? String)?.hasPrefix("23 ") == true, "Header shows the timeline count: \(String(describing: count.value))")

        // Open the first photo in the loupe.
        cells.firstMatch.doubleClick()
        XCTAssertTrue(app.descendants(matching: .any)["loupe"].waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.screenshot("2-loupe", in: self)

        // Info overlay (I) shows the histogram.
        app.typeKey("i", modifierFlags: [])
        XCTAssertTrue(app.descendants(matching: .any)["info-overlay"].waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.screenshot("3-info-overlay", in: self)
        app.typeKey("i", modifierFlags: [])

        // Arrow keys step through photos; Esc returns to the grid.
        for _ in 0..<3 { app.typeKey(.rightArrow, modifierFlags: []) }
        sleep(1)
        UITestSupport.screenshot("4-loupe-after-arrows", in: self)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(grid.waitForExistence(timeout: 5))

        // Grid size shortcut and panels toggle (Tab).
        app.typeKey("=", modifierFlags: .command)
        app.typeKey(.tab, modifierFlags: [])
        sleep(1)
        UITestSupport.screenshot("5-grid-larger-no-panels", in: self)
        app.typeKey(.tab, modifierFlags: [])
    }

    func testLivePhotoPlaysAndSidebarNavigates() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        // Open the first item, then step through the loupe until a Live Photo is shown.
        let first = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.doubleClick()
        let play = app.descendants(matching: .any)["play-live"]
        var steps = 0
        while !play.waitForExistence(timeout: 1.5) && steps < 30 {
            app.typeKey(.rightArrow, modifierFlags: [])
            steps += 1
        }
        XCTAssertTrue(play.exists, "A Live Photo should be reachable in the loupe")
        play.click()
        let player = app.descendants(matching: .any)["video-player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), "Clicking LIVE should play the motion")
        sleep(1)
        UITestSupport.screenshot("6-live-playing", in: self)
        // Space also plays it (after the clip ends the still returns).
        XCTAssertTrue(play.waitForExistence(timeout: 10), "The still returns when the motion ends")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(player.waitForExistence(timeout: 10), "Space should play the motion")
        app.typeKey(.escape, modifierFlags: [])

        UITestSupport.sidebar(app, "Favorites").click()
        XCTAssertTrue(app.staticTexts["destination-title"].waitForExistence(timeout: 5))
        let favCount = app.staticTexts["item-count"]
        XCTAssertTrue(favCount.waitForExistence(timeout: 10))
        let predicate = NSPredicate(format: "value BEGINSWITH '2 '")
        expectation(for: predicate, evaluatedWith: favCount)
        waitForExpectations(timeout: 10)
        UITestSupport.screenshot("7-favorites", in: self)
    }
}
