import XCTest

/// Feedback round: Back to grid keeps the place, Edit button and labelled tools, date bar jumps and hover,
/// Memories under Collections (Folders gone), hiding a person.
@MainActor
final class NavigationUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }
    private func any(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    func testBackEditScrubberMemoriesAndPeople() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // Sidebar: Memories is a collection; Folders is gone.
        XCTAssertTrue(UITestSupport.sidebar(app, "Memories").exists)
        XCTAssertFalse(any(app, "sidebar-Folders").exists)

        // Open the last photo in the grid, then come back with the Grid button: it is still on screen.
        let photos = cells(app).matching(NSPredicate(format: "label == 'Photo'")).allElementsBoundByIndex
        let target = try XCTUnwrap(photos.last)
        let id = target.identifier
        target.doubleClick()
        let back = any(app, "back-to-grid")
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back to grid button in the loupe")
        XCTAssertTrue(any(app, "edit-photo").exists, "Edit button in the loupe")
        back.click()
        let returned = app.images[id]
        XCTAssertTrue(returned.waitForExistence(timeout: 10))
        XCTAssertTrue(returned.isHittable, "Grid returns to the photo you were on")
        // Info panel: the date and location values are the edit links; one Edit button (no Develop segment).
        XCTAssertTrue(any(app, "info-edit-date").waitForExistence(timeout: 10), "Date is a link")
        XCTAssertTrue(any(app, "info-edit-location").exists, "Location is a link")
        XCTAssertEqual(any(app, "mode-picker").radioButtons.count, 2, "Grid and single-photo only")

        // Edit button opens Develop with labelled tools; Back goes to the photo, then to the grid.
        returned.click()
        any(app, "edit-photo").click()
        XCTAssertTrue(any(app, "develop-crop").waitForExistence(timeout: 15))
        XCTAssertTrue(any(app, "develop-rotate-left").exists && any(app, "develop-flip").exists)
        UITestSupport.screenshot("fb-1-develop-tools", in: self)
        // Cancel discards changes and closes the editor without saving.
        app.sliders["slider-Exposure"].adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertTrue(any(app, "develop-unsaved").waitForExistence(timeout: 5))
        app.buttons["develop-cancel"].click()
        XCTAssertTrue(any(app, "loupe").waitForExistence(timeout: 10), "Cancel shows the photo")
        XCTAssertFalse(app.staticTexts["status-message"].exists && ((app.staticTexts["status-message"].value as? String) ?? "").contains("Saved"),
                       "Cancel saves nothing")
        any(app, "edit-photo").click()
        XCTAssertTrue(any(app, "develop-crop").waitForExistence(timeout: 15))
        XCTAssertFalse(any(app, "develop-unsaved").exists, "Reopening shows no leftover changes")

        // Any way out of the editor with unsaved changes asks first, e.g. the toolbar's view switcher.
        app.sliders["slider-Exposure"].adjust(toNormalizedSliderPosition: 0.62)
        XCTAssertTrue(any(app, "develop-unsaved").waitForExistence(timeout: 5))
        any(app, "mode-picker").radioButtons.element(boundBy: 0).click()
        let keep = app.sheets.buttons["Keep Editing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Switching views asks about unsaved edits")
        UITestSupport.screenshot("fb-3-unsaved-prompt", in: self)
        keep.click()
        XCTAssertTrue(any(app, "develop-crop").waitForExistence(timeout: 5), "Keep Editing stays in the editor")
        XCTAssertTrue(any(app, "develop-unsaved").exists)
        // The G key asks too; Don't Save discards and continues.
        app.typeKey("g", modifierFlags: [])
        let dontSave = app.sheets.buttons["Don’t Save"]
        XCTAssertTrue(dontSave.waitForExistence(timeout: 5))
        dontSave.click()
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 10), "Don't Save continues to the grid")
        returned.click()
        any(app, "edit-photo").click()
        XCTAssertTrue(any(app, "develop-crop").waitForExistence(timeout: 15))
        XCTAssertFalse(any(app, "develop-unsaved").exists, "Nothing was saved or kept")
        any(app, "back-to-grid").click()
        XCTAssertTrue(any(app, "loupe").waitForExistence(timeout: 10), "Back from Develop shows the photo")
        // Side arrows move between photos.
        let next = any(app, "loupe-next"), previous = any(app, "loupe-previous")
        XCTAssertTrue(previous.exists || next.exists, "Side arrows")
        if previous.exists && previous.isEnabled { previous.click() } else { next.click() }
        sleep(1)
        let idLabel = app.staticTexts["loupe-asset-id"]
        let current = idLabel.exists ? ((idLabel.value as? String) ?? idLabel.label) : ""
        XCTAssertFalse(current.isEmpty, "Loupe exposes the shown photo")
        any(app, "back-to-grid").click()
        let shown = app.images["asset-\(current)"]
        XCTAssertTrue(shown.waitForExistence(timeout: 10), "Grid shows the photo you were on")
        sleep(1)
        XCTAssertTrue(shown.isHittable, "…and it is on screen")

        // A single click on a Live Photo in the loupe plays it.
        cells(app).firstMatch.doubleClick()
        let play = any(app, "play-live")
        var steps = 0
        while !play.waitForExistence(timeout: 1.5) && steps < 30 { app.typeKey(.rightArrow, modifierFlags: []); steps += 1 }
        if play.exists {
            any(app, "loupe").click()
            XCTAssertTrue(any(app, "video-player").waitForExistence(timeout: 5), "A click plays the Live Photo")
        }
        app.typeKey("g", modifierFlags: [])

        // Date bar: hover shows month and year; clicking a month scrolls there.
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 10))
        let months = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'scrubber-m-'"))
        let lastMonth = try XCTUnwrap(months.allElementsBoundByIndex.last)
        lastMonth.hover()
        XCTAssertTrue(any(app, "scrubber-hover").waitForExistence(timeout: 3), "Hover shows the month and year")
        UITestSupport.screenshot("fb-2-scrubber-hover", in: self)
        let firstID = cells(app).firstMatch.identifier
        lastMonth.click()
        sleep(1)
        XCTAssertFalse(app.images[firstID].isHittable, "Clicking an old month scrolls away from the newest photos")

        // Memories view.
        UITestSupport.go(app, "Memories")
        XCTAssertTrue(any(app, "memories-view").waitForExistence(timeout: 10))

        // Right-click a Live Photo in the grid ▸ Play Live Photo.
        UITestSupport.go(app, "Photos")
        let live = cells(app).matching(NSPredicate(format: "label == 'Live Photo'")).firstMatch
        if live.waitForExistence(timeout: 10) {
            live.rightClick()
            let play = app.menuItems.matching(NSPredicate(format: "title == 'Play Live Photo'")).allElementsBoundByIndex.first { $0.isHittable }
            try XCTUnwrap(play, "Play Live Photo in the menu").click()
            XCTAssertTrue(any(app, "video-player").waitForExistence(timeout: 10), "Live Photo plays")
            app.typeKey(.escape, modifierFlags: [])
        }

        // People: hover shows a hide button; hide, show hidden, unhide.
        UITestSupport.go(app, "People")
        let person = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch
        if person.waitForExistence(timeout: 15) {
            let personID = String(person.identifier.dropFirst("person-".count))
            person.hover()
            let hide = any(app, "hide-person-\(personID)")
            XCTAssertTrue(hide.waitForExistence(timeout: 3), "Hide button on hover")
            hide.click()
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: any(app, "person-\(personID)"))
            waitForExpectations(timeout: 10)
            any(app, "people-show-hidden").click()
            XCTAssertTrue(any(app, "hide-person-\(personID)").waitForExistence(timeout: 10))
            any(app, "hide-person-\(personID)").click()   // show again
            sleep(2)
            any(app, "people-show-hidden").click()
            XCTAssertTrue(any(app, "person-\(personID)").waitForExistence(timeout: 10), "Person shown again")
        }
    }
}
