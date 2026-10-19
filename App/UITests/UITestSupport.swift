import XCTest

/// Shared helpers: isolated launch, sign-in to the test server, screenshots.
@MainActor
enum UITestSupport {
    struct Account: Decodable { let email: String; let password: String }
    struct Credentials: Decodable { let admin: Account; let user: Account }

    static var credentials: Credentials? {
        guard let path = ProcessInfo.processInfo.environment["DARKROOM_TEST_CREDENTIALS"] else { return nil }
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { try? JSONDecoder().decode(Credentials.self, from: $0) }
    }

    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DARKROOM_DATA_DIR"] = FileManager.default.temporaryDirectory
            .appending(path: "darkroom-ui-\(UUID().uuidString)").path
        app.launchEnvironment["DARKROOM_SECRETS"] = "memory"
        app.launchEnvironment["DARKROOM_DISABLE_BIOMETRICS"] = "1"
        app.launchEnvironment["DARKROOM_DISCOVERY_CANDIDATES"] = "http://127.0.0.1:9,http://localhost:2283"
        app.launch()
        return app
    }

    /// Signs in (via the discovered test server) and sets a PIN; returns once the library is visible.
    static func signIn(_ app: XCUIApplication, as account: KeyPath<Credentials, Account> = \.admin, pin: String = "2580") throws {
        let creds = try XCTUnwrap(credentials, "Test server credentials missing")[keyPath: account]
        XCTAssertTrue(app.buttons["found-localhost:2283"].waitForExistence(timeout: 10))
        app.textFields["email"].click(); app.textFields["email"].typeText(creds.email)
        app.secureTextFields["password"].click(); app.secureTextFields["password"].typeText(creds.password)
        app.buttons["sign-in"].click()
        let pinField = app.secureTextFields["pin"]
        XCTAssertTrue(pinField.waitForExistence(timeout: 15))
        pinField.click(); pinField.typeText(pin)
        app.secureTextFields["pin-confirm"].click(); app.secureTextFields["pin-confirm"].typeText(pin)
        app.buttons["pin-save"].click()
    }

    static func screenshot(_ name: String, in test: XCTestCase) {
        let attachment = XCTAttachment(screenshot: XCUIApplication().windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}
