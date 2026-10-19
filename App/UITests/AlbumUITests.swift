import XCTest

@MainActor
final class AlbumUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func deleteAlbumIfPresent(_ app: XCUIApplication, _ name: String) {
        let entry = UITestSupport.sidebar(app, "album-\(name)")
        guard entry.waitForExistence(timeout: 3) else { return }
        entry.click()
        any(app, "album-more").click()
        app.menuItems["Delete Album…"].click()
        sleep(1)
        let confirm = app.windows.firstMatch.descendants(matching: .button).matching(NSPredicate(format: "title == 'Delete Album' OR label == 'Delete Album'"))
            .allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(confirm, "Delete confirmation")
        confirm?.click()
        sleep(2)
    }

    func testCreateAlbumDragPhotoShareLinkAndDelete() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        let name = "UITest Album"
        deleteAlbumIfPresent(app, name)

        // Albums overview shows the seeded album.
        UITestSupport.sidebar(app, "Albums").click()
        XCTAssertTrue(any(app, "album-Sample Album").waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.screenshot("m3b-1-albums", in: self)

        // Create an album.
        any(app, "new-album").click()
        let field = app.textFields["new-album-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.buttons["sheet-confirm"].click()
        let sidebarAlbum = UITestSupport.sidebar(app, "album-\(name)")
        XCTAssertTrue(sidebarAlbum.waitForExistence(timeout: 10), "New album appears in the sidebar")

        // Drag a photo from the grid onto the album in the sidebar.
        UITestSupport.sidebar(app, "Photos").click()
        let photo = cells(app).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.click()
        photo.press(forDuration: 0.6, thenDragTo: sidebarAlbum)
        let status = app.staticTexts["status-message"]
        expectation(for: NSPredicate(format: "value CONTAINS 'Add to'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)

        // Open it: one photo, header with Share / Link.
        sidebarAlbum.click()
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 15), "The dropped photo is in the album")
        XCTAssertEqual(cells(app).count, 1)
        XCTAssertTrue(any(app, "album-share").exists)
        any(app, "album-link").click()
        app.buttons["create-link"].click()
        let url = app.staticTexts["shared-link-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        XCTAssertTrue((url.value as? String ?? "").contains("/share/"))
        UITestSupport.screenshot("m3b-2-link", in: self)
        app.typeKey(.return, modifierFlags: [])

        // Share sheet lists the other user.
        any(app, "album-share").click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'invite-'")).firstMatch.waitForExistence(timeout: 10))
        UITestSupport.screenshot("m3b-3-share", in: self)
        app.typeKey(.return, modifierFlags: [])

        // Sharing view lists the link; delete it, then delete the album (photos stay).
        UITestSupport.sidebar(app, "Sharing").click()
        XCTAssertTrue(any(app, "sharing").waitForExistence(timeout: 10))
        sleep(2)
        UITestSupport.screenshot("m3b-4-sharing", in: self)
        for button in app.buttons.matching(NSPredicate(format: "title == 'Delete'")).allElementsBoundByIndex { button.click(); sleep(1) }
        deleteAlbumIfPresent(app, name)
        XCTAssertFalse(any(app, "sidebar-album-\(name)").exists)
        UITestSupport.sidebar(app, "Photos").click()
        let count = app.staticTexts["item-count"]
        expectation(for: NSPredicate(format: "value BEGINSWITH '23 '"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
    }
}
