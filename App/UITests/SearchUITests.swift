import XCTest

@MainActor
final class SearchUITests: XCTestCase {
    private func cells(_ app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'asset-'"))
    }

    func testSmartSearchAndFilters() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        // ⌘F focuses search; Return runs a smart (CLIP) search.
        app.typeKey("f", modifierFlags: .command)
        let field = app.textFields["search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("trees\r")
        let title = app.staticTexts["destination-title"]
        expectation(for: NSPredicate(format: "value CONTAINS 'trees'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20), "Smart search should find photos")
        sleep(2)
        UITestSupport.screenshot("m2-1-smart-search", in: self)

        // Filters: videos only (no text).
        app.textFields["search-field"].click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        app.buttons["search-filters"].click()
        let media = app.descendants(matching: .any)["filter-media"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.radioButtons["Videos"].click()
        sleep(1)
        UITestSupport.screenshot("m2-2-filters", in: self)
        app.buttons["filter-search"].click()
        expectation(for: NSPredicate(format: "value CONTAINS 'Videos'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))
        sleep(2)
        let labels = cells(app).allElementsBoundByIndex.map(\.label)
        XCTAssertFalse(labels.isEmpty)
        XCTAssertTrue(labels.allSatisfy { $0 == "Video" }, "Only videos: \(labels)")
        UITestSupport.screenshot("m2-3-videos", in: self)

        // Back returns to the previous search.
        app.buttons["back"].click()
        expectation(for: NSPredicate(format: "value CONTAINS 'trees'"), evaluatedWith: title)
        waitForExpectations(timeout: 10)
    }

    func testExplorePlacesMapAndPeople() throws {
        let app = UITestSupport.launch()
        try UITestSupport.signIn(app)
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20))

        app.descendants(matching: .any)["sidebar-Explore"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["explore-Videos"].firstMatch.waitForExistence(timeout: 10))
        sleep(3)
        UITestSupport.screenshot("m2-4-explore", in: self)

        app.descendants(matching: .any)["sidebar-Places"].firstMatch.click()
        let place = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'place-'")).firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 15), "Places should list cities")
        sleep(2)
        UITestSupport.screenshot("m2-5-places", in: self)
        place.click()
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20), "A place opens its photos")
        sleep(1)
        UITestSupport.screenshot("m2-6-place-photos", in: self)

        app.descendants(matching: .any)["sidebar-Map"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["map-count"].waitForExistence(timeout: 15))
        sleep(4)
        UITestSupport.screenshot("m2-7-map", in: self)
        let inView = app.buttons["map-photos-in-view"]
        XCTAssertTrue(inView.isEnabled)
        inView.click()
        XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 30), "Photos in view open as a grid")
        sleep(1)
        UITestSupport.screenshot("m2-8-map-selection", in: self)

        app.descendants(matching: .any)["sidebar-People"].firstMatch.click()
        let person = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch
        let empty = app.descendants(matching: .any)["people-empty"]
        let deadline = Date().addingTimeInterval(15)
        while !person.exists && !empty.exists && Date() < deadline { usleep(300_000) }
        XCTAssertTrue(person.exists || empty.exists)
        sleep(2)
        UITestSupport.screenshot("m2-9-people", in: self)
        if person.exists {
            person.click()
            XCTAssertTrue(cells(app).firstMatch.waitForExistence(timeout: 20), "A person opens their photos")
        }
    }
}
