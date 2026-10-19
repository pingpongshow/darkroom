import XCTest

@MainActor
final class UtilitiesUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testCollectionsUtilitiesLockedFolderAndSlideshow() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Slideshow (⌘↩) and Esc.
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(any(app, "slideshow").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "slideshow-image").waitForExistence(timeout: 10), "Slideshow shows a photo")
        sleep(3)
        UITestSupport.screenshot("m3c-1-slideshow", in: self)
        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(2)
        UITestSupport.screenshot("m3c-1b-slideshow-next", in: self)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(any(app, "slideshow").waitForExistence(timeout: 2))

        for (sidebar, shot) in [("Recently Added", "m3c-2-recent"), ("Large Files", "m3c-3-large")] {
            UITestSupport.sidebar(app, "\(sidebar)").click()
            XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20), "\(sidebar) shows photos")
            sleep(1)
            UITestSupport.screenshot(shot, in: self)
        }

        // Folders → a folder's photos.
        UITestSupport.sidebar(app, "Folders").click()
        let folder = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'folder-'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        UITestSupport.screenshot("m3c-4-folders", in: self)
        folder.click()
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20), "Folder shows its photos")

        // Tags: create, then delete.
        UITestSupport.sidebar(app, "Tags").click()
        let field = app.textFields["tags-new"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click(); field.typeText("UITestTag\r")
        let tag = any(app, "tag-UITestTag")
        XCTAssertTrue(tag.waitForExistence(timeout: 10))
        UITestSupport.screenshot("m3c-5-tags", in: self)
        tag.rightClick()
        let delete = app.menuItems.matching(NSPredicate(format: "title == 'Delete Tag'")).allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(delete).click()
        XCTAssertFalse(tag.waitForExistence(timeout: 3))

        // Duplicates and bursts load.
        UITestSupport.sidebar(app, "Duplicates").click()
        sleep(2)
        UITestSupport.screenshot("m3c-6-duplicates", in: self)
        UITestSupport.sidebar(app, "Bursts").click()
        sleep(3)
        UITestSupport.screenshot("m3c-7-bursts", in: self)

        // Locked folder: PIN gate (the integration tests set the test server's Immich PIN).
        UITestSupport.sidebar(app, "Locked Folder").click()
        let pin = app.secureTextFields["locked-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 10))
        UITestSupport.screenshot("m3c-8-locked-gate", in: self)
        pin.click(); pin.typeText("135790\r")
        XCTAssertFalse(pin.waitForExistence(timeout: 5), "Unlocked")
        UITestSupport.sidebar(app, "Photos").click()
        UITestSupport.sidebar(app, "Locked Folder").click()
        XCTAssertTrue(app.secureTextFields["locked-pin"].waitForExistence(timeout: 10), "Leaving locks it again")
    }
}
