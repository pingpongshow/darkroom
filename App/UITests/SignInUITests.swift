import XCTest

/// Drives the real app against the stock test server (scripts/test-server.sh tunnel).
/// Uses an isolated data folder and in-memory secrets, so real accounts are never touched.
@MainActor
final class SignInUITests: XCTestCase {
    static var credentials: UITestSupport.Credentials? { UITestSupport.credentials }

    func launch() -> XCUIApplication { UITestSupport.launch() }

    func testSignInSetPINSwitchAndUnlock() throws {
        let creds = try XCTUnwrap(Self.credentials, "Test server credentials missing")
        let app = launch()

        // The test server is discovered automatically and pre-selected.
        let discovered = app.buttons["found-localhost:2283"]
        XCTAssertTrue(discovered.waitForExistence(timeout: 10), "Test server should be discovered")
        app.textFields["email"].click(); app.textFields["email"].typeText(creds.user.email)
        app.secureTextFields["password"].click(); app.secureTextFields["password"].typeText(creds.user.password)
        app.buttons["sign-in"].click()

        let pin = app.secureTextFields["pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 15),
                      "PIN setup should follow sign-in; error=\(app.staticTexts["sign-in-error"].value ?? "none")")
        pin.click(); pin.typeText("2580")
        app.secureTextFields["pin-confirm"].click(); app.secureTextFields["pin-confirm"].typeText("2580")
        app.buttons["pin-save"].click()

        XCTAssertTrue(app.descendants(matching: .any)["photo-grid"].waitForExistence(timeout: 15), "Library should open")

        // Switch user -> picker -> unlock with wrong then right PIN
        app.typeKey("u", modifierFlags: [.command, .shift])
        let tile = app.buttons["account-\(creds.user.email)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.click()
        let unlock = app.secureTextFields["unlock-pin"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 5))
        unlock.typeText("1111\r")
        let wrong = app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'Wrong PIN'")).firstMatch
        XCTAssertTrue(wrong.waitForExistence(timeout: 5),
                      "Wrong-PIN message should appear")
        unlock.click(); unlock.typeText("2580\r")
        XCTAssertTrue(app.descendants(matching: .any)["photo-grid"].waitForExistence(timeout: 15))
    }

    func testWrongPasswordShowsError() throws {
        let creds = try XCTUnwrap(Self.credentials)
        let app = launch()
        // Manual entry still works.
        XCTAssertTrue(app.buttons["found-localhost:2283"].waitForExistence(timeout: 10))
        app.descendants(matching: .any)["manual-entry"].firstMatch.click()
        let server = app.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.doubleClick(); server.typeKey("a", modifierFlags: .command); server.typeText("http://localhost:2283")
        app.textFields["email"].click(); app.textFields["email"].typeText(creds.user.email)
        app.secureTextFields["password"].click(); app.secureTextFields["password"].typeText("not-the-password")
        app.buttons["sign-in"].click()
        XCTAssertTrue(app.staticTexts["sign-in-error"].waitForExistence(timeout: 10))
    }
}
