import XCTest

/// Organising actions. Every change is undone (⌘Z) so the seeded library stays the same.
@MainActor
final class OrganizeUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }

    private func count(_ app: XCUIApplication) -> Int {
        let value = app.staticTexts["item-count"].value as? String ?? ""
        return Int(value.split(separator: " ").first ?? "") ?? -1
    }

    private func waitForCount(_ app: XCUIApplication, _ expected: Int, _ message: String) {
        let deadline = Date().addingTimeInterval(15)
        while count(app) != expected && Date() < deadline { usleep(250_000) }
        XCTAssertEqual(count(app), expected, message)
    }

    private func status(_ app: XCUIApplication, contains text: String) {
        let status = app.staticTexts["status-message"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", text), evaluatedWith: status)
        waitForExpectations(timeout: 10)
    }

    private func go(_ app: XCUIApplication, _ sidebar: String) {
        UITestSupport.go(app, sidebar)
        sleep(1)
    }

    func testFavoriteRatingTrashWithUndo() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        waitForCount(app, 23, "Seeded library")

        go(app, "Trash")
        sleep(2)
        let trashBefore = max(0, count(app))
        go(app, "Favorites")
        sleep(1)
        let favorites = count(app)
        go(app, "Photos")
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Favourite with H, check the Favorites count, undo.
        let first = cells(app).firstMatch
        first.click()
        app.typeKey("h", modifierFlags: [])
        status(app, contains: "avorite")
        go(app, "Favorites")
        waitForCount(app, favorites + 1, "Favorite added (or \(favorites - 1) if it already was one)")
        app.typeKey("z", modifierFlags: .command)
        status(app, contains: "Undo")
        go(app, "Photos")
        go(app, "Favorites")
        waitForCount(app, favorites, "Undo restores favorites")
        go(app, "Photos")
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Rating 4 from the keyboard shows in the info panel; undo clears it.
        cells(app).firstMatch.click()
        app.typeKey("4", modifierFlags: [])
        status(app, contains: "Rate 4")
        sleep(2)
        UITestSupport.screenshot("m3-1-rated", in: self)
        app.typeKey("z", modifierFlags: .command)
        status(app, contains: "Undo")

        // Delete key moves to Immich's trash; undo restores.
        cells(app).firstMatch.click()
        app.typeKey(.delete, modifierFlags: [])
        status(app, contains: "Move to Trash")
        waitForCount(app, 22, "Trashed item leaves the timeline")
        go(app, "Trash")
        waitForCount(app, trashBefore + 1, "Item is in the trash")
        XCTAssertTrue(app.buttons["empty-trash"].exists)
        UITestSupport.screenshot("m3-2-trash", in: self)
        app.typeKey("z", modifierFlags: .command)
        status(app, contains: "Undo")
        go(app, "Photos")
        waitForCount(app, 23, "Undo restores from trash")
    }

    func testContextMenuAndSheets() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        cells(app).firstMatch.rightClick()
        // The same items exist in the menu bar's Photo menu; use the visible context-menu ones.
        func contextItem(_ title: String) -> XCUIElement? {
            app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable }
        }
        sleep(1)
        let dateItem = try XCTUnwrap(contextItem("Adjust Date & Time…"))
        XCTAssertNotNil(contextItem("Move to Trash"))
        XCTAssertNotNil(contextItem("Download Original…"))
        UITestSupport.screenshot("m3-3-context-menu", in: self)
        dateItem.click()
        XCTAssertTrue(app.descendants(matching: .any)["date-shift"].waitForExistence(timeout: 5))
        sleep(2)
        UITestSupport.screenshot("m3-4-date-sheet", in: self)
        app.typeKey(.escape, modifierFlags: [])

        // Metadata sheet from the Photo menu shortcut.
        app.typeKey("m", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["meta-tags"].waitForExistence(timeout: 5))
        UITestSupport.screenshot("m3-5-metadata-sheet", in: self)
        app.typeKey(.escape, modifierFlags: [])

        // Geotag sheet.
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.descendants(matching: .any)["geotag-map"].waitForExistence(timeout: 5))
        sleep(2)
        UITestSupport.screenshot("m3-6-geotag", in: self)
        app.typeKey(.escape, modifierFlags: [])
    }
}
